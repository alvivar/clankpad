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
/// One fresh Pi process is spawned per [streamEdit] invocation. Pi owns all
/// auth and model configuration — Clankpad has no API key management.
class PiRpcService {
  PiRpcService({this.piExecutable = 'pi'});

  /// Executable name or absolute path. Defaults to `pi` (resolved via PATH).
  final String piExecutable;

  Process? _process;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Spawns Pi, sends the editing prompt, and yields text chunks as they arrive.
  ///
  /// Completes normally when `agent_end` is received — including after [abort].
  /// Throws [PiRpcError] on process launch failure or unrecoverable model error.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
  }) async* {
    final message = _buildPromptMessage(
      documentText,
      editTarget,
      userInstruction,
    );

    // ── Spawn ─────────────────────────────────────────────────────────────────

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

    // ── Send prompt ───────────────────────────────────────────────────────────

    proc.stdin.writeln(jsonEncode({'type': 'prompt', 'message': message}));
    await proc.stdin.flush();

    // ── Stream events ─────────────────────────────────────────────────────────

    bool agentEndReceived = false;

    try {
      await for (final line
          in proc.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue; // skip malformed lines
        }

        final type = event['type'] as String?;

        // prompt command acknowledgement — check before events start flowing
        if (type == 'response') {
          if (event['command'] == 'prompt' && event['success'] != true) {
            throw const PiRpcError(
              'Pi process exited unexpectedly — try again.',
            );
          }
          continue; // other response types (e.g. abort ack) are ignored
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

        // Clean completion
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
      _process = null;
      // Kill Pi on error/unexpected-exit paths. On a clean abort Pi emits
      // agent_end before exiting, so agentEndReceived will be true.
      if (!agentEndReceived) proc.kill();
    }

    if (!agentEndReceived) {
      throw const PiRpcError('Pi process exited unexpectedly — try again.');
    }
  }

  /// Sends `{"type":"abort"}` to Pi's stdin.
  ///
  /// Pi stops generation and emits `agent_end`, completing the stream normally.
  /// Safe to call when no stream is active — does nothing.
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

  /// Kills the Pi process and marks this service as disposed.
  /// After [dispose], [streamEdit] returns an empty stream immediately.
  Future<void> dispose() async {
    final proc = _process;
    if (proc == null) return;
    _process = null;
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
