import 'package:flutter/material.dart';

import '../services/markdown_styles.dart';

/// A [TextEditingController] that styles Markdown syntax and paints highlight
/// layers via [buildTextSpan], independently of whether the editor has focus.
///
/// **Markdown** — [scanMarkdown] styles the whole text; delimiters stay
/// visible but dimmed. Only the scan is cached (per text); styles are composed
/// on every build.
///
/// **Search matches** (`setMatches` / `clearMatches`) — painted while the find
/// bar is open. Dark mode uses dedicated VS Code match colors; light mode
/// uses `primaryContainer` and `primary` at 35 % opacity for the current match.
///
/// **Edit target** (`setEditTarget` / `clearEditTarget`) — painted while the
/// Ctrl+K popup or AI diff is active, showing the user what text will be (or
/// was) edited. Uses `tertiaryContainer`.
///
/// The text is split at every layer boundary, so layers combine wherever they
/// overlap; search matches and the edit target coexist when Find stays open
/// under the Ctrl+K popup. Background priority: current match, other match,
/// edit target, code.
class HighlightingController extends TextEditingController {
  HighlightingController.fromValue(super.value) : super.fromValue();

  // Layer bits. Bits below [_matchBit] are [MarkdownKind] indexes.
  static final _matchBit = MarkdownKind.values.length;
  static final _currentMatchBit = _matchBit + 1;
  static final _editTargetBit = _matchBit + 2;
  static final _composingBit = _matchBit + 3;

  // ── Search-match layer ───────────────────────────────────────────────────────

  List<int> _matchOffsets = const [];
  int _queryLength = 0;
  int _currentIndex = -1;

  void setMatches(List<int> offsets, int queryLength, int currentIndex) {
    _matchOffsets = offsets;
    _queryLength = queryLength;
    _currentIndex = currentIndex;
    notifyListeners();
  }

  void clearMatches() {
    if (_matchOffsets.isEmpty) return; // skip spurious rebuilds
    _matchOffsets = const [];
    _queryLength = 0;
    _currentIndex = -1;
    notifyListeners();
  }

  // ── Edit-target layer ────────────────────────────────────────────────────────

  int _editTargetStart = -1;
  int _editTargetEnd = -1;

  void setEditTarget(int start, int end) {
    _editTargetStart = start;
    _editTargetEnd = end;
    notifyListeners();
  }

  void clearEditTarget() {
    if (_editTargetStart == -1) return; // skip spurious rebuilds
    _editTargetStart = -1;
    _editTargetEnd = -1;
    notifyListeners();
  }

  // ── Rendering ────────────────────────────────────────────────────────────────

  String? _scannedText;
  List<MarkdownRun> _markdownRuns = const [];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    if (text != _scannedText) {
      _markdownRuns = scanMarkdown(text);
      _scannedText = text;
    }

    // Each layer sets its bit over [start, end); a piece of text is styled
    // from the set of bits covering it.
    final events = <(int, int, int)>[]; // (offset, bit, +1 or -1)
    void addLayer(int start, int end, int bit) {
      if (end <= start) return;
      events
        ..add((start, bit, 1))
        ..add((end, bit, -1));
    }

    for (final run in _markdownRuns) {
      addLayer(run.start, run.end, run.kind.index);
    }
    if (_editTargetStart >= 0) {
      addLayer(
        _editTargetStart.clamp(0, text.length),
        _editTargetEnd.clamp(0, text.length),
        _editTargetBit,
      );
    }
    if (_queryLength > 0) {
      for (var i = 0; i < _matchOffsets.length; i++) {
        final start = _matchOffsets[i];
        if (start >= text.length) break;
        addLayer(
          start,
          (start + _queryLength).clamp(0, text.length),
          i == _currentIndex ? _currentMatchBit : _matchBit,
        );
      }
    }
    if (withComposing && value.isComposingRangeValid) {
      addLayer(value.composing.start, value.composing.end, _composingBit);
    }

    if (events.isEmpty) return TextSpan(style: style, text: text);
    events.sort((a, b) => a.$1.compareTo(b.$1));

    final colors = _LayerColors.of(Theme.of(context).colorScheme);
    final styles = <int, TextStyle?>{};
    final counts = List.filled(_composingBit + 1, 0);
    final children = <TextSpan>[];
    var mask = 0;
    var pieceStart = 0;
    void addPiece(int end) {
      if (end <= pieceStart) return;
      children.add(
        TextSpan(
          text: text.substring(pieceStart, end),
          style: styles.putIfAbsent(mask, () => _styleFor(mask, colors)),
        ),
      );
      pieceStart = end;
    }

    for (final (offset, bit, delta) in events) {
      counts[bit] += delta;
      final next = counts[bit] > 0 ? mask | 1 << bit : mask & ~(1 << bit);
      if (next == mask) continue;
      addPiece(offset);
      mask = next;
    }
    addPiece(text.length);
    return TextSpan(style: style, children: children);
  }

  /// The style the layers in [mask] add to the base style.
  static TextStyle? _styleFor(int mask, _LayerColors colors) {
    if (mask == 0) return null;
    bool has(int bit) => mask & 1 << bit != 0;
    bool kind(MarkdownKind kind) => has(kind.index);

    // 0–5 for heading1–heading6, which come first in MarkdownKind.
    final level = MarkdownKind.values.sublist(0, 6).indexWhere(kind);
    final heading = level != -1;
    final code = kind(MarkdownKind.code);
    final decorations = [
      if (kind(MarkdownKind.strikethrough) && !code) TextDecoration.lineThrough,
      if (has(_composingBit)) TextDecoration.underline,
    ];

    return TextStyle(
      // On the current match, token colors lose too much contrast; the text
      // keeps the body color and delimiters a lighter dim.
      color: kind(MarkdownKind.delimiter)
          ? has(_currentMatchBit)
                ? colors.currentMatchDelimiter
                : colors.delimiter
          : has(_currentMatchBit)
          ? null
          : code
          ? colors.code
          : kind(MarkdownKind.link)
          ? colors.link
          : kind(MarkdownKind.listMarker)
          ? colors.listMarker
          : heading
          ? colors.heading
          : kind(MarkdownKind.quote)
          ? colors.quote
          : null,
      backgroundColor: has(_currentMatchBit)
          ? colors.currentMatch
          : has(_matchBit)
          ? colors.match
          : has(_editTargetBit)
          ? colors.editTarget
          : code
          ? colors.codeBackground
          : null,
      // H1–H3 grow; H4–H6 keep the body size (14).
      fontSize: switch (level) {
        0 => 20,
        1 => 18,
        2 => 16,
        _ => null,
      },
      fontWeight: heading || (kind(MarkdownKind.bold) && !code)
          ? FontWeight.bold
          : null,
      fontStyle: kind(MarkdownKind.italic) && !code ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
    );
  }
}

/// Markdown colors are inspired by VS Code's Dark Modern / Light Modern
/// Markdown tokens. The dimmed delimiter colors keep at least 3:1 contrast on
/// the code, search and edit-target backgrounds.
class _LayerColors {
  const _LayerColors({
    required this.heading,
    required this.code,
    required this.codeBackground,
    required this.quote,
    required this.listMarker,
    required this.link,
    required this.delimiter,
    required this.currentMatchDelimiter,
    required this.match,
    required this.currentMatch,
    required this.editTarget,
  });

  factory _LayerColors.of(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? _LayerColors(
          heading: const Color(0xFF569CD6),
          code: const Color(0xFFCE9178),
          codeBackground: const Color(0xFF2B2B2B),
          quote: const Color(0xFF6A9955),
          listMarker: const Color(0xFF6796E6),
          link: const Color(0xFF4DAAFC),
          delimiter: const Color(0xFF9D9D9D),
          currentMatchDelimiter: const Color(0xFFB0B0B0),
          // Search highlights must not share the blue action / status-chip
          // roles.
          match: const Color(0x55EA5C00),
          currentMatch: const Color(0xFF515C6A),
          editTarget: scheme.tertiaryContainer,
        )
      : _LayerColors(
          heading: const Color(0xFF800000),
          code: const Color(0xFFA31515),
          codeBackground: const Color(0xFFE8ECEF),
          quote: const Color(0xFF2E7D32),
          listMarker: const Color(0xFF0451A5),
          link: const Color(0xFF005FB8),
          delimiter: const Color(0xFF616161),
          currentMatchDelimiter: const Color(0xFF616161),
          match: scheme.primaryContainer,
          currentMatch: scheme.primary.withValues(alpha: 0.35),
          editTarget: scheme.tertiaryContainer,
        );

  final Color heading;
  final Color code;
  final Color codeBackground;
  final Color quote;
  final Color listMarker;
  final Color link;
  final Color delimiter;
  final Color currentMatchDelimiter;
  final Color match;
  final Color currentMatch;
  final Color editTarget;
}

class EditorTab {
  final int id;
  String? filePath;
  String title;

  // The text content at the last save point. Used to compute isDirty.
  // For untitled tabs that have never been saved, this is an empty string.
  String savedContent;

  // Source of truth for current text in the editor.
  final HighlightingController controller;

  // Preserves scroll position per tab. Passed directly to the TextField so
  // the same TextField element can be reused across tab switches without
  // resetting scroll.
  final ScrollController scrollController;

  // Drives only the ● dot in the tab chip. Updated by the controller listener
  // in EditorState — never triggers a full EditorState rebuild.
  final ValueNotifier<bool> isDirtyNotifier;

  EditorTab({
    required this.id,
    this.filePath,
    required this.title,
    this.savedContent = '',
    String initialContent = '',
  }) : controller = HighlightingController.fromValue(
         TextEditingValue(
           text: initialContent,
           // Explicit offset 0 instead of the default -1. A -1 selection is
           // invalid and EditableText will not render a cursor for it unless
           // a focus-change event fires to correct it — which never happens
           // on the keyboard-shortcut path where focus stays on the same node.
           selection: const TextSelection.collapsed(offset: 0),
         ),
       ),
       scrollController = ScrollController(),
       // Initialise dirty state immediately so restored tabs and newly-loaded
       // content show the correct ● indicator before the user types.
       isDirtyNotifier = ValueNotifier<bool>(initialContent != savedContent);

  bool get isDirty => isDirtyNotifier.value;

  // Called by EditorState when this tab is removed from the list.
  void dispose() {
    controller.dispose();
    scrollController.dispose();
    isDirtyNotifier.dispose();
  }
}
