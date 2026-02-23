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
/// Pi is spawned on the first [streamEdit] call and kept alive between
/// invocations. Each call sends `new_session` + `prompt` back-to-back to
/// reset Pi's in-memory conversation history before each edit. Pi owns all
/// auth and model configuration — Clankpad has no API key management.
class PiRpcService {
  PiRpcService({this.piExecutable = 'pi'});

  /// Executable name or absolute path. Defaults to `pi` (resolved via PATH).
  final String piExecutable;

  Process? _process;

  // Persistent subscription forwarding stdout lines to the per-invocation
  // controller. Created at spawn time, cancelled only in dispose() or on error.
  StreamSubscription<String>? _stdoutSub;

  // Per-invocation sink. Created at the start of streamEdit, closed in finally.
  // _stdoutSub writes to it; streamEdit reads from it.
  StreamController<String>? _lineController;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Spawns Pi on the first call (or after a crash), reuses the warm process
  /// on subsequent calls. Yields text chunks as they arrive.
  ///
  /// Completes normally when `agent_end` is received — including after [abort].
  /// Throws [PiRpcError] on process launch failure or unrecoverable model error.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
  }) async* {
    // ── Ensure warm process ────────────────────────────────────────────────────

    if (_process == null) {
      await _spawn(); // throws PiRpcError if pi not found
    }

    // ── Per-invocation line controller ────────────────────────────────────────

    final controller = StreamController<String>();
    _lineController = controller;

    // ── Send new_session + prompt (back-to-back, one flush) ──────────────────
    //
    // new_session clears Pi's in-memory conversation history so each edit is
    // independent. Its acknowledgement arrives as type=="response" and is
    // silently ignored by the event loop below (same as the abort ack).

    final message = _buildPromptMessage(
      documentText,
      editTarget,
      userInstruction,
    );
    _process!.stdin.writeln(jsonEncode({'type': 'new_session'}));
    _process!.stdin.writeln(jsonEncode({'type': 'prompt', 'message': message}));
    await _process!.stdin.flush();

    // ── Stream events ─────────────────────────────────────────────────────────

    bool agentEndReceived = false;

    try {
      await for (final line in controller.stream) {
        if (line.trim().isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue; // skip malformed lines
        }

        final type = event['type'] as String?;

        // Response acks (new_session, abort, prompt success) arrive here.
        // Only act on a failing prompt ack; everything else is ignored.
        if (type == 'response') {
          if (event['command'] == 'prompt' && event['success'] != true) {
            throw const PiRpcError(
              'Pi process exited unexpectedly — try again.',
            );
          }
          continue;
        }

        // Token chunk
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

        // Clean completion — process stays warm
        if (type == 'agent_end') {
          agentEndReceived = true;
          break;
        }

        // All retries exhausted
        if (type == 'auto_retry_end' && event['success'] == false) {
          throw const PiRpcError('Pi process exited unexpectedly — try again.');
        }

        // All other events (turn_start, message_start, thinking_delta, etc.)
        // are silently ignored.
      }
    } finally {
      _lineController = null;
      if (!controller.isClosed) await controller.close();
      // Kill Pi only on error/unexpected-exit paths. On success and after
      // abort Pi emits agent_end (agentEndReceived = true) — stay warm.
      if (!agentEndReceived) {
        await _killProcess();
      }
    }

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
    } catch (_) {
      // stdin may already be closed; nothing to do.
    }
  }

  /// Cancels the stdout subscription, closes the line controller, kills Pi.
  Future<void> dispose() async {
    final c = _lineController;
    _lineController = null;
    if (c != null && !c.isClosed) await c.close();
    await _killProcess();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  Future<void> _spawn() async {
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

    // Drain stderr so the pipe never blocks the child process.
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});

    // Persistent subscription: forwards every stdout line to the active
    // per-invocation controller. Survives across streamEdit calls.
    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _lineController?.add(line),
          onDone: _onProcessExit,
          onError: (_) => _onProcessExit(),
        );
  }

  /// Called when Pi's stdout closes — either because Pi exited unexpectedly
  /// or (if somehow reached) after explicit process termination.
  void _onProcessExit() {
    _process = null;
    _stdoutSub = null;
    // Close the active controller so the await for in streamEdit exits and
    // the error path (kill + throw PiRpcError) runs. No-op if already closed
    // or if called between invocations (controller is null).
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
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      await proc.stdin.close();
    } catch (_) {}
    proc.kill();
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
