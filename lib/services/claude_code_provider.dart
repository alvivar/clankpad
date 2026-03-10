import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';

/// [AiProvider] backed by the Claude Code CLI (`claude -p`).
///
/// Each [streamEdit] call spawns a new `claude` process. Claude Code manages
/// its own model and auth configuration — Clankpad only passes the prompt.
/// [fetchModels] returns an empty list because Claude Code does not expose a
/// queryable model catalogue.
class ClaudeCodeProvider implements AiProvider {
  ClaudeCodeProvider({this.claudeExecutable = 'claude'});

  /// Executable name or absolute path. Defaults to `claude` (resolved via PATH).
  final String claudeExecutable;

  Process? _activeProcess;
  bool _aborted = false;
  String? _lastWarning;

  @override
  String get name => 'Claude Code';

  @override
  String? get lastWarning => _lastWarning;

  // ── Public API ──────────────────────────────────────────────────────────────

  // Hardcoded model catalogue. Update when Anthropic ships new models.
  static const _models = <Map<String, dynamic>>[
    {
      'id': 'claude-opus-4-6',
      'name': 'Claude Opus 4.6',
      'provider': 'anthropic',
      'reasoning': true,
    },
    {
      'id': 'claude-sonnet-4-6',
      'name': 'Claude Sonnet 4.6',
      'provider': 'anthropic',
      'reasoning': true,
    },
    {
      'id': 'claude-haiku-4-5',
      'name': 'Claude Haiku 4.5',
      'provider': 'anthropic',
      'reasoning': true,
    },
  ];

  @override
  Future<AiProviderModels> fetchModels() async {
    return const AiProviderModels(
      models: _models,
      suggestedProvider: 'anthropic',
      suggestedModelId: 'claude-sonnet-4-6',
      suggestedThinkingLevel: 'medium',
    );
  }

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
    _lastWarning = null;
    _aborted = false;

    final prompt = AiProvider.buildPromptMessage(
      documentText,
      editTarget,
      userInstruction,
      insertOffset: insertOffset,
    );

    final args = [
      '-p',
      prompt,
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
    ];

    if (modelId != null) {
      args.addAll(['--model', modelId]);
    }

    // Map thinking level to --effort flag. Omit when 'off' (Claude's default).
    if (thinkingLevel != 'off') {
      args.addAll(['--effort', thinkingLevel]);
    }

    final Process proc;
    try {
      proc = await Process.start(
        claudeExecutable,
        args,
        // Required on Windows: the npm global install creates claude.cmd,
        // not claude.exe, and Process.start only resolves .cmd wrappers
        // via the shell.
        runInShell: true,
      );
    } on ProcessException {
      throw AiProviderError(
        '`$claudeExecutable` not found — install Claude Code and ensure '
        "it's on PATH.",
      );
    }

    _activeProcess = proc;

    // Collect stderr for error reporting if the process fails.
    final stderrBuf = StringBuffer();
    proc.stderr
        .transform(utf8.decoder)
        .listen((data) => stderrBuf.write(data));

    bool anyOutput = false;

    try {
      await for (final line in proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        // Claude Code stream-json format:
        //   { "type": "stream_event", "event": { "delta": { "type": "text_delta", "text": "..." } } }
        if (event['type'] == 'stream_event') {
          final inner = event['event'] as Map<String, dynamic>?;
          final delta = inner?['delta'] as Map<String, dynamic>?;
          if (delta?['type'] == 'text_delta') {
            final text = delta!['text'] as String?;
            if (text != null && text.isNotEmpty) {
              anyOutput = true;
              yield text;
            }
          }
        }
      }

      // stdout closed — process is exiting or already exited.
      // Only check exit code if we weren't aborted by the user.
      if (!_aborted) {
        final exitCode = await proc.exitCode;
        if (exitCode != 0 && !anyOutput) {
          final errMsg = stderrBuf.toString().trim();
          throw AiProviderError(
            errMsg.isNotEmpty
                ? errMsg
                : 'Claude Code exited with code $exitCode',
          );
        }
      }
    } finally {
      _activeProcess = null;
    }
  }

  @override
  void abort() {
    _aborted = true;
    _activeProcess?.kill();
    _activeProcess = null;
  }

  @override
  Future<void> dispose() async {
    _activeProcess?.kill();
    _activeProcess = null;
  }
}
