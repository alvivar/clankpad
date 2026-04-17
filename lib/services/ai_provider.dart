/// Thrown when an AI provider fails to complete a request.
class AiProviderError implements Exception {
  final String message;
  const AiProviderError(this.message);

  @override
  String toString() => message;
}

/// Result of [AiProvider.fetchModels]: the filtered model list plus optional
/// defaults suggested by the provider (e.g. Pi's live state via `get_state`).
class AiProviderModels {
  final List<Map<String, dynamic>> models;

  /// Suggested model to pre-select (provider may return null).
  final String? suggestedProvider;
  final String? suggestedModelId;

  /// Suggested thinking level (defaults to 'off').
  final String suggestedThinkingLevel;

  const AiProviderModels({
    this.models = const [],
    this.suggestedProvider,
    this.suggestedModelId,
    this.suggestedThinkingLevel = 'off',
  });
}

/// Backend-agnostic interface for AI-assisted text editing.
///
/// Each provider (Pi, Claude Code, …) implements this to supply models and
/// stream edited text. The UI layer ([EditorScreen]) holds one or more
/// providers and delegates to whichever the user has selected.
abstract class AiProvider {
  /// Human-readable name shown in the provider picker (e.g. "Pi").
  String get name;

  /// Fetches available models (filtered and ready to display) plus optional
  /// suggested defaults. Returns an empty [AiProviderModels] when the
  /// provider does not expose a queryable model list.
  Future<AiProviderModels> fetchModels();

  /// Streams edited-text chunks for the given instruction.
  ///
  /// Completes normally when generation is finished.
  /// Throws [AiProviderError] on process/network failure.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
    String? modelProvider,
    String? modelId,
    String thinkingLevel = 'off',
    int? insertOffset,
  });

  /// Cancels the in-flight request. Safe to call when idle (no-op).
  void abort();

  /// Releases all resources (kills subprocess, etc.).
  Future<void> dispose();

  /// Non-fatal warning from the most recent [streamEdit] call
  /// (e.g. model switch was rejected but the prompt still ran).
  String? get lastWarning;

  // ── Shared prompt construction ────────────────────────────────────────────

  /// System prompt passed to every provider (`pi --system-prompt` /
  /// `claude --system-prompt`). Frames the model as a text-editor assistant
  /// rather than a coding agent — both Pi and Claude Code default to a
  /// coding-agent system prompt, which biases output toward code fences,
  /// tool usage, and verbose explanations. The per-request prompts built by
  /// [buildPromptMessage] still include `IMPORTANT:` contract lines as
  /// belt-and-suspenders.
  ///
  /// Kept as a single line (adjacent-string concatenation) so it can be
  /// passed through `Process.start` on Windows without multi-line argv
  /// quoting issues.
  static const String systemPrompt =
      'You are an assistant embedded in a text editor. '
      "Your job is to transform text according to the user's instruction. "
      'Return ONLY the requested output text. '
      'Do not include explanations, preambles, commentary, or surrounding '
      'markdown code fences unless the user explicitly asks for them. '
      "Preserve the document's style, tone, formatting, indentation, and "
      'structure unless the user asks to change them. '
      'The document may contain prose, notes, markdown, lists, or code.';

  /// Builds the prompt message sent to the model. Shared across all providers
  /// because the editing contract (document + target + instruction) is the
  /// same regardless of backend.
  static String buildPromptMessage(
    String documentText,
    String editTarget,
    String userInstruction, {
    int? insertOffset,
  }) {
    if (editTarget.isEmpty) {
      // Insert mode: embed a [CURSOR] marker so the model sees the full
      // document as a coherent whole with a precise insertion point.
      final offset = insertOffset ?? documentText.length;
      final before = documentText.substring(0, offset);
      final after = documentText.substring(offset);
      return 'Document:\n'
          '$before[CURSOR]$after\n'
          '\n'
          'Instruction: $userInstruction\n'
          '\n'
          'IMPORTANT: Reply with ONLY the text to insert at [CURSOR]. '
          'Do not include surrounding blank lines. No explanations, no preamble.';
    }
    return 'Document context:\n'
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
}
