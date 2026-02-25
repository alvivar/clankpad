import 'package:flutter/material.dart';

/// A [TextEditingController] that paints search-match highlights via
/// [buildTextSpan], independently of whether the editor has focus.
///
/// Call [setMatches] when the active query or current index changes.
/// Call [clearMatches] when the find bar closes.
class HighlightingController extends TextEditingController {
  HighlightingController.fromValue(TextEditingValue value)
    : super.fromValue(value);

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

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_matchOffsets.isEmpty || _queryLength == 0) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    // All matches get a container tint; the current match gets a stronger one.
    final otherColor = colorScheme.primaryContainer;
    final currentColor = colorScheme.primary.withOpacity(0.35);

    final text = this.text;
    final spans = <TextSpan>[];
    var cursor = 0;

    for (var i = 0; i < _matchOffsets.length; i++) {
      final start = _matchOffsets[i];
      final end = (start + _queryLength).clamp(0, text.length);
      if (start >= text.length) break;

      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start), style: style));
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: (style ?? const TextStyle()).copyWith(
            backgroundColor: i == _currentIndex ? currentColor : otherColor,
          ),
        ),
      );
      cursor = end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }

    return TextSpan(style: style, children: spans);
  }
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
       isDirtyNotifier = ValueNotifier<bool>(false);

  bool get isDirty => isDirtyNotifier.value;

  // Called by EditorState when this tab is removed from the list.
  void dispose() {
    controller.dispose();
    scrollController.dispose();
    isDirtyNotifier.dispose();
  }
}
