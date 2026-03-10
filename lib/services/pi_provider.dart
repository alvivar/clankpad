import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';

/// [AiProvider] backed by Pi's RPC subprocess (`pi --mode rpc`).
///
/// Pi is spawned on the first [fetchModels] or [streamEdit] call and kept alive
/// between invocations. Pi owns all auth and model configuration — Clankpad
/// has no API key management.
class PiProvider implements AiProvider {
  PiProvider({this.piExecutable = 'pi'});

  /// Executable name or absolute path. Defaults to `pi` (resolved via PATH).
  final String piExecutable;

  Process? _process;

  // Persistent subscription forwarding stdout lines to the per-invocation
  // controller. Created at spawn time, cancelled only in dispose() or on error.
  StreamSubscription<String>? _stdoutSub;

  // Per-invocation sink. Created at the start of streamEdit, closed in finally.
  StreamController<String>? _lineController;

  // For sendCommand — used only for get_available_models at popup open.
  // _pendingCommands is always empty during active streaming.
  int _cmdCounter = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingCommands = {};

  // Set when set_model or set_thinking_level returns success: false.
  // Cleared at the start of each streamEdit call. Callers read this after
  // the stream ends to surface a non-fatal warning.
  String? _lastWarning;

  @override
  String get name => 'Pi';

  @override
  String? get lastWarning => _lastWarning;

  // ── Public API ──────────────────────────────────────────────────────────────

  @override
  Future<AiProviderModels> fetchModels() async {
    await _ensureRunning();

    final results = await Future.wait<dynamic>([
      sendCommand({'type': 'get_available_models'}),
      // get_state is best-effort — wrap so a failure doesn't poison
      // the whole Future.wait and leave the model list empty.
      sendCommand({'type': 'get_state'}).catchError(
        (_) => <String, dynamic>{},
      ),
      loadEnabledModelPatterns(),
    ]);

    final modelsResp = results[0] as Map<String, dynamic>;
    final stateResp = results[1] as Map<String, dynamic>;
    final patterns = results[2] as List<String>?;

    final all =
        (modelsResp['data']['models'] as List).cast<Map<String, dynamic>>();

    // Apply enabledModels filter from ~/.pi/agent/settings.json.
    // Fall back to full list if patterns are null/empty or every
    // model is excluded (avoids a blank dropdown on bad config).
    final filtered =
        (patterns != null && patterns.isNotEmpty)
            ? all
                .where(
                  (m) => matchesEnabledPattern(
                    '${m['provider']}/${m['id']}',
                    patterns,
                  ),
                )
                .toList()
            : all;
    final models = filtered.isNotEmpty ? filtered : all;

    // Extract Pi's live state for seeding suggestions.
    final stateData = stateResp['data'] as Map<String, dynamic>?;
    final piLevel = stateData?['thinkingLevel'] as String? ?? 'off';
    final piModel = stateData?['model'] as Map<String, dynamic>?;
    final piModelId = piModel?['id'] as String?;
    final piProvider = piModel?['provider'] as String?;

    // Only suggest the model if it's in the (possibly filtered) list.
    final inList =
        piModelId != null &&
        piProvider != null &&
        models.any((m) => m['id'] == piModelId && m['provider'] == piProvider);

    return AiProviderModels(
      models: models,
      suggestedProvider: inList ? piProvider : null,
      suggestedModelId: inList ? piModelId : null,
      suggestedThinkingLevel: piLevel,
    );
  }

  /// Sends a command with a unique `id` and awaits its `response` event.
  ///
  /// Used only for out-of-band queries (e.g. `get_available_models`) that need
  /// data back before streaming starts. Throws [AiProviderError] on timeout
  /// (5 s) or `success: false`.
  Future<Map<String, dynamic>> sendCommand(Map<String, dynamic> cmd) async {
    await _ensureRunning();
    final id = 'c${_cmdCounter++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[id] = completer;
    _process!.stdin.writeln(jsonEncode({...cmd, 'id': id}));
    await _process!.stdin.flush();
    final response = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingCommands.remove(id);
        throw AiProviderError("Command timed out: ${cmd['type']}");
      },
    );
    if (response['success'] == false) {
      throw AiProviderError(
        response['error'] as String? ?? "Command failed: ${cmd['type']}",
      );
    }
    return response;
  }

  /// Spawns Pi on the first call (or after a crash), reuses the warm process
  /// on subsequent calls. Yields text chunks as they arrive.
  ///
  /// When [modelId] is non-null, `set_model` is sent before `new_session`.
  /// `set_thinking_level` is always sent — Pi ignores it for non-reasoning
  /// models, so no guard is needed here.
  ///
  /// Completes normally when `agent_end` is received — including after [abort].
  /// Throws [AiProviderError] on process launch failure or unrecoverable error.
  @override
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
    String? modelProvider,
    String? modelId,
    String thinkingLevel = 'off',
    int? insertOffset,
  }) async* {
    _lastWarning = null; // clear from any previous call
    await _ensureRunning();

    final controller = StreamController<String>();
    _lineController = controller;
    String? modelSwitchError;

    // Send all commands in one flush:
    //   [set_model] → [set_thinking_level] → new_session → prompt
    if (modelId != null) {
      _process!.stdin.writeln(
        jsonEncode({
          'type': 'set_model',
          'provider': modelProvider,
          'modelId': modelId,
        }),
      );
    }
    _process!.stdin.writeln(
      jsonEncode({'type': 'set_thinking_level', 'level': thinkingLevel}),
    );
    _process!.stdin.writeln(jsonEncode({'type': 'new_session'}));
    _process!.stdin.writeln(
      jsonEncode({
        'type': 'prompt',
        'message': AiProvider.buildPromptMessage(
          documentText,
          editTarget,
          userInstruction,
          insertOffset: insertOffset,
        ),
      }),
    );
    await _process!.stdin.flush();

    bool agentEndReceived = false;

    try {
      await for (final line in controller.stream) {
        if (line.trim().isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final type = event['type'] as String?;

        // Response acks — id-tagged ones never reach here (routed by
        // _processLine to _pendingCommands). Check success on the ones
        // that matter; silently skip the rest (new_session, abort).
        if (type == 'response') {
          // set_model / set_thinking_level failures are non-fatal: Pi falls
          // back to its current model/level and the prompt still runs.
          if (event['command'] == 'set_model' && event['success'] != true) {
            modelSwitchError = event['error'] as String? ?? 'set_model failed';
          }
          if (event['command'] == 'set_thinking_level' &&
              event['success'] != true) {
            modelSwitchError ??=
                event['error'] as String? ?? 'set_thinking_level failed';
          }
          if (event['command'] == 'prompt' && event['success'] != true) {
            throw const AiProviderError(
              'Pi process exited unexpectedly — try again.',
            );
          }
          continue;
        }

        // Token chunk.
        if (type == 'message_update') {
          final ame = event['assistantMessageEvent'] as Map<String, dynamic>?;
          if (ame?['type'] == 'text_delta') {
            final chunk = ame!['delta'] as String?;
            if (chunk != null && chunk.isNotEmpty) {
              yield chunk;
            }
          }
          continue;
        }

        // Clean completion — process stays warm.
        if (type == 'agent_end') {
          agentEndReceived = true;
          break;
        }

        // All retries exhausted.
        if (type == 'auto_retry_end' && event['success'] == false) {
          throw const AiProviderError(
            'Pi process exited unexpectedly — try again.',
          );
        }
      }
    } finally {
      _lineController = null;
      if (!controller.isClosed) await controller.close();
      if (!agentEndReceived) {
        await _killProcess();
      }
    }

    _lastWarning = modelSwitchError;

    if (!agentEndReceived) {
      throw const AiProviderError(
        'Pi process exited unexpectedly — try again.',
      );
    }
  }

  /// Sends `{"type":"abort"}` to Pi's stdin.
  ///
  /// Pi stops generation and emits `agent_end`, completing the stream normally.
  /// The process stays warm. Safe to call when no stream is active — no-op.
  @override
  void abort() {
    final proc = _process;
    if (proc == null) return;
    try {
      proc.stdin.writeln(jsonEncode({'type': 'abort'}));
      proc.stdin.flush().ignore();
    } catch (_) {}
  }

  /// Cancels the stdout subscription, completes pending commands with an error,
  /// and kills Pi.
  @override
  Future<void> dispose() async {
    for (final c in _pendingCommands.values) {
      c.completeError(const AiProviderError('Service disposed'));
    }
    _pendingCommands.clear();

    final c = _lineController;
    _lineController = null;
    if (c != null && !c.isClosed) await c.close();
    await _killProcess();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  /// Spawns Pi if it is not already running; returns immediately if warm.
  Future<void> _ensureRunning() async {
    if (_process != null) return;

    final Process proc;
    try {
      proc = await Process.start(
        piExecutable,
        [
          '--mode',
          'rpc',
          '--no-session',
          '--no-tools',
          '--no-extensions',
          '--no-skills',
          '--no-prompt-templates',
        ],
        // Required on Windows: the npm global install creates pi.cmd, not
        // pi.exe, and Process.start only resolves .cmd wrappers via the shell.
        runInShell: true,
      );
    } on ProcessException {
      throw AiProviderError(
        '`$piExecutable` not found — install it with '
        '`npm install -g @mariozechner/pi-coding-agent` and ensure it\'s on PATH.',
      );
    }

    _process = proc;

    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});

    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _processLine,
          onDone: _onProcessExit,
          onError: (_) => _onProcessExit(),
        );
  }

  /// Routes each stdout line: id-tagged `response` events go to the matching
  /// [Completer] in [_pendingCommands]; everything else forwards to
  /// [_lineController]. During active streaming, [_pendingCommands] is always
  /// empty so the routing branch is a constant-time no-op.
  void _processLine(String line) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      _lineController?.add(line);
      return;
    }
    if (event['type'] == 'response' && event['id'] is String) {
      _pendingCommands.remove(event['id'] as String)?.complete(event);
      return; // do NOT forward to _lineController
    }
    _lineController?.add(line);
  }

  /// Called when Pi's stdout closes — either an unexpected exit or after
  /// explicit termination.
  void _onProcessExit() {
    _process = null;
    _stdoutSub = null;
    // Complete any in-flight sendCommand calls with an error.
    for (final c in _pendingCommands.values) {
      c.completeError(
        const AiProviderError('Pi process exited unexpectedly.'),
      );
    }
    _pendingCommands.clear();
    final c = _lineController;
    _lineController = null;
    if (c != null && !c.isClosed) c.close();
  }

  /// Cancels the stdout subscription and kills the process.
  /// Idempotent — safe to call multiple times.
  Future<void> _killProcess() async {
    final proc = _process;
    if (proc == null) return;
    _process = null;
    proc.kill();
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      await proc.stdin.close();
    } catch (_) {}
  }

  // ── enabledModels filtering ─────────────────────────────────────────────────

  /// Reads `~/.pi/agent/settings.json` and returns the `enabledModels` list,
  /// or `null` if the file is absent, malformed, or the key is missing/empty.
  /// Never throws — callers treat `null` as "show all models".
  static Future<List<String>?> loadEnabledModelPatterns() async {
    try {
      final home =
          Platform.environment['USERPROFILE'] ?? // Windows
          Platform.environment['HOME']; // macOS / Linux
      if (home == null) return null;
      final file = File('$home/.pi/agent/settings.json');
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final raw = json['enabledModels'];
      if (raw is! List || raw.isEmpty) return null;
      return raw.cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// Returns `true` if [modelId] matches any of [patterns].
  /// Glob rules: `*` matches any sequence of characters; everything else is
  /// treated as a literal (including `/`).
  static bool matchesEnabledPattern(String modelId, List<String> patterns) {
    for (final pattern in patterns) {
      // Split on '*', escape each literal segment, rejoin with '.*'.
      final segments = pattern.split('*').map(RegExp.escape).join('.*');
      if (RegExp('^$segments\$').hasMatch(modelId)) return true;
    }
    return false;
  }
}
