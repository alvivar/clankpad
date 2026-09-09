/// Thrown when an AI provider fails to complete a request.
class AiProviderError implements Exception {
  final String message;
  const AiProviderError(this.message);

  @override
  String toString() => message;
}

/// A single AI model exposed by a provider.
///
/// Identity is `(provider, id)`; [name] is for display and [supportsReasoning]
/// is a capability bit driving the thinking-level picker.
class AiModel {
  final String provider;
  final String id;
  final String name;
  final bool supportsReasoning;

  const AiModel({
    required this.provider,
    required this.id,
    required this.name,
    this.supportsReasoning = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiModel && other.provider == provider && other.id == id;

  @override
  int get hashCode => Object.hash(provider, id);
}

/// Pi's filtered model list plus optional defaults suggested by its live state.
class AiProviderModels {
  final List<AiModel> models;

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

/// System prompt passed to Pi via `--system-prompt`. Frames the model as a
/// text-editor assistant rather than a coding agent, whose default system
/// prompt biases output toward code fences, tool usage, and verbose
/// explanations. The per-request prompts built by [buildPromptMessage] still
/// include `IMPORTANT:` contract lines as belt-and-suspenders.
///
/// Kept as a single line (adjacent-string concatenation) so it can be passed
/// through `Process.start` on Windows without multi-line argv quoting issues.
const String systemPrompt =
    'You are an assistant embedded in a text editor. '
    "Your job is to transform text according to the user's instruction. "
    'Return ONLY the requested output text. '
    'Do not include explanations, preambles, commentary, or surrounding '
    'markdown code fences unless the user explicitly asks for them. '
    "Preserve the document's language, style, tone, formatting, "
    'indentation, and structure unless the user asks to change them. '
    'The document may contain prose, notes, markdown, lists, or code.';

/// Sentinel marking the insertion point in insert-mode prompts. Pure ASCII
/// and deliberately unlovely: it tokenises predictably across every model Pi
/// can route to (including small/old ones) and never collides with real document
/// text. The model is told never to echo it back.
const String cursorMarker = '<<<CLANKPAD_CURSOR>>>';

/// Builds the prompt message sent to the model.
String buildPromptMessage(
  String documentText,
  String editTarget,
  String userInstruction, {
  int? insertOffset,
}) {
  if (editTarget.isEmpty) {
    // Insert mode: embed a cursor marker so the model sees the full document as
    // a coherent whole with a precise insertion point.
    final offset = insertOffset ?? documentText.length;
    final before = documentText.substring(0, offset);
    final after = documentText.substring(offset);
    return 'Document:\n'
        '$before$cursorMarker$after\n'
        '\n'
        'Instruction: $userInstruction\n'
        '\n'
        'IMPORTANT: Reply with ONLY the text to insert at $cursorMarker. '
        'The cursor marker is not part of the document; never include it in '
        'your reply. Do not add leading/trailing blank lines unless required '
        'to satisfy the instruction. No explanations, no preamble, no '
        'markdown fences.';
  }
  return 'Full document context:\n'
      '$documentText\n'
      '\n'
      'Edit target to replace (copied verbatim from the document above):\n'
      '$editTarget\n'
      '\n'
      'Instruction: $userInstruction\n'
      '\n'
      'IMPORTANT: Return ONLY the replacement for the Edit target. '
      'Do not echo any surrounding document text. Preserve leading/trailing '
      'whitespace and blank lines unless required to satisfy the instruction. '
      'No explanations, no preamble, no markdown fences.';
}
