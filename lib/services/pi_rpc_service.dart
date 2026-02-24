import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown when Pi fails to complete the editing request.
class PiRpcError implements Exception {
  final String message;
  const PiRpcError(this.message);

  @override
  String toString() => message;
}

/// Drives Pi's RPC subprocess (`pi --mode rpc`) for AI-assisted text editing.
///
/// Pi is spawned on the first [warmUp] or [streamEdit] call and kept alive
/// between invocations. Pi owns all auth and model configuration — Clankpad
/// has no API key management.
class PiRpcService {
  PiRpcService({this.piExecutable = 'pi'});

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
  String? _lastModelSwitchError;

  /// Non-null after a streamEdit call if set_model or set_thinking_level
  /// was rejected by Pi. The prompt still ran with Pi's current model.
  String? get lastModelSwitchError => _lastModelSwitchError;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Pre-warms the Pi process in the background. Called when the Ctrl+K popup
  /// opens so the process is ready before the user submits.
  Future<void> warmUp() => _ensureRunning();

  /// Sends a command with a unique `id` and awaits its `response` event.
  ///
  /// Used only for out-of-band queries (e.g. `get_available_models`) that need
  /// data back before streaming starts. Throws [PiRpcError] on timeout (5 s)
  /// or `success: false`.
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
        throw PiRpcError("Command timed out: ${cmd['type']}");
      },
    );
    if (response['success'] == false) {
      throw PiRpcError(
        response['error'] as String? ?? "Command failed: ${cmd['type']}",
      );
    }
    return response;
  }

  /// Spawns Pi on the first call (or after a crash), reuses the warm process
  /// on subsequent calls. Yields text chunks as they arrive.
  ///
  /// When [modelId] is non-null, `set_model` is sent before `new_session`.
  /// When [modelSupportsThinking] is true, `set_thinking_level` is also sent.
  ///
  /// Completes normally when `agent_end` is received — including after [abort].
  /// Throws [PiRpcError] on process launch failure or unrecoverable model error.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
    String? modelProvider,
    String? modelId,
    bool modelSupportsThinking = false,
    String thinkingLevel = 'medium',
  }) async* {
    _lastModelSwitchError = null; // clear from any previous call
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
    if (modelId != null && modelSupportsThinking) {
      _process!.stdin.writeln(
        jsonEncode({'type': 'set_thinking_level', 'level': thinkingLevel}),
      );
    }
    _process!.stdin.writeln(jsonEncode({'type': 'new_session'}));
    _process!.stdin.writeln(
      jsonEncode({
        'type': 'prompt',
        'message': _buildPromptMessage(
          documentText,
          editTarget,
          userInstruction,
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
            throw const PiRpcError(
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
          throw const PiRpcError('Pi process exited unexpectedly — try again.');
        }
      }
    } finally {
      _lineController = null;
      if (!controller.isClosed) await controller.close();
      if (!agentEndReceived) {
        await _killProcess();
      }
    }

    _lastModelSwitchError = modelSwitchError;

    if (!agentEndReceived) {
      throw const PiRpcError('Pi process exited unexpectedly — try again.');
    }
  }

  /// Sends `{"type":"abort"}` to Pi's stdin.
  ///
  /// Pi stops generation and emits `agent_end`, completing the stream normally.
  /// The process stays warm. Safe to call when no stream is active — no-op.
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
  Future<void> dispose() async {
    for (final c in _pendingCommands.values) {
      c.completeError(const PiRpcError('Service disposed'));
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
      throw PiRpcError(
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
      c.completeError(const PiRpcError('Pi process exited unexpectedly.'));
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

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _buildPromptMessage(
    String documentText,
    String editTarget,
    String userInstruction,
  ) =>
      'Document context:\n'
      '$documentText\n'
      '\n'
      'Edit target:\n'
      '$editTarget\n'
      '\n'
      'Instruction: $userInstruction\n'
      '\n'
      'IMPORTANT: Reply with ONLY the transformed text. '
      'No explanations, no preamble.';
}
