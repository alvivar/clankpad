import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/editor_tab.dart';

class EditorArea extends StatelessWidget {
  static const _indent = '    '; // 4 spaces

  final EditorTab tab;
  final bool readOnly;
  // Persistent FocusNode supplied by EditorScreen so that focus can be
  // explicitly restored after popups and diffs are dismissed.
  final FocusNode focusNode;

  const EditorArea({
    super.key,
    required this.tab,
    required this.focusNode,
    this.readOnly = false,
  });

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (readOnly) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }

    final controller = tab.controller;
    final selection = controller.selection;
    if (!selection.isValid) return KeyEventResult.handled;

    if (HardwareKeyboard.instance.isShiftPressed) {
      _outdent(controller, selection);
    } else {
      _indentSelectionOrInsert(controller, selection);
    }
    return KeyEventResult.handled;
  }

  void _indentSelectionOrInsert(
    TextEditingController controller,
    TextSelection selection,
  ) {
    if (selection.isCollapsed) {
      final caret = selection.extentOffset;
      if (caret < 0) return;
      final text = controller.text;
      controller.value = TextEditingValue(
        text: '${text.substring(0, caret)}$_indent${text.substring(caret)}',
        selection: TextSelection.collapsed(offset: caret + _indent.length),
      );
      return;
    }

    _transformSelectedLines(controller, selection, outdent: false);
  }

  void _outdent(TextEditingController controller, TextSelection selection) {
    if (selection.isCollapsed) {
      final caret = selection.extentOffset;
      if (caret <= 0) return;
      final text = controller.text;

      var remove = 0;
      while (remove < _indent.length &&
          caret - remove - 1 >= 0 &&
          text.codeUnitAt(caret - remove - 1) == 0x20) {
        remove++;
      }
      if (remove == 0) return;

      controller.value = TextEditingValue(
        text: text.replaceRange(caret - remove, caret, ''),
        selection: TextSelection.collapsed(offset: caret - remove),
      );
      return;
    }

    _transformSelectedLines(controller, selection, outdent: true);
  }

  void _transformSelectedLines(
    TextEditingController controller,
    TextSelection selection, {
    required bool outdent,
  }) {
    final text = controller.text;
    if (text.isEmpty) return;

    final starts = _lineStarts(text);
    final lines = text.split('\n');

    int lineAt(int offset) {
      var lo = 0;
      var hi = starts.length - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (starts[mid] <= offset) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return hi < 0 ? 0 : hi;
    }

    final startOffset = selection.start.clamp(0, text.length);
    var endOffset = selection.end.clamp(0, text.length);
    if (endOffset > startOffset &&
        endOffset > 0 &&
        text.codeUnitAt(endOffset - 1) == 0x0A) {
      // If selection ends exactly on a line break, don't include the next line.
      endOffset--;
    }

    final firstLine = lineAt(startOffset);
    final lastLine = lineAt(endOffset);

    final edits = <(int, int, int)>[]; // (pos, deleteLen, insertLen)

    for (var i = firstLine; i <= lastLine; i++) {
      final pos = starts[i];
      if (outdent) {
        final line = lines[i];
        var remove = 0;
        while (remove < _indent.length &&
            remove < line.length &&
            line.codeUnitAt(remove) == 0x20) {
          remove++;
        }
        if (remove == 0) continue;
        lines[i] = line.substring(remove);
        edits.add((pos, remove, 0));
      } else {
        lines[i] = '$_indent${lines[i]}';
        edits.add((pos, 0, _indent.length));
      }
    }

    if (edits.isEmpty) return;

    int mapOffset(int offset) {
      if (offset <= 0) return 0;
      if (offset > text.length) offset = text.length;

      var delta = 0;
      for (final edit in edits) {
        final pos = edit.$1;
        final deleteLen = edit.$2;
        final insertLen = edit.$3;

        if (offset < pos) continue;

        if (deleteLen > 0 && offset <= pos + deleteLen) {
          return pos + delta + insertLen;
        }

        delta += insertLen - deleteLen;
      }
      return offset + delta;
    }

    final newText = lines.join('\n');
    final newBase = mapOffset(selection.baseOffset).clamp(0, newText.length);
    final newExtent = mapOffset(selection.extentOffset).clamp(0, newText.length);

    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: newBase, extentOffset: newExtent),
    );
  }

  static List<int> _lineStarts(String text) {
    final starts = <int>[0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surface,
      child: Focus(
        onKeyEvent: (_, event) => _handleKeyEvent(event),
        child: TextField(
          // No ValueKey — the same TextField element is reused across tab
          // switches. Only controller and scrollController change, so focus
          // never leaves the element during a tab switch.
          controller: tab.controller,
          scrollController: tab.scrollController,
          focusNode: focusNode,
          // autofocus fires once when the TextField is first inserted (app
          // startup). After that, focus is managed explicitly via focusNode.
          autofocus: true,
          readOnly: readOnly,

          // Word wrap on, vertical scroll only (Phase 1 default).
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,

          style: const TextStyle(
            fontFamily: 'Consolas',
            fontSize: 14,
            height: 1.6,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(16),
            // Suppress the default focus ring / underline on desktop.
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
          ),
          cursorWidth: 1.5,
        ),
      ),
    );
  }
}
