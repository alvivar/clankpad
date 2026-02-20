import 'package:flutter/widgets.dart';

class EditorTab {
  final int id;
  String? filePath;
  String title;

  // The text content at the last save point. Used to compute isDirty.
  // For untitled tabs that have never been saved, this is an empty string.
  String savedContent;

  // Source of truth for current text in the editor.
  final TextEditingController controller;

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
  })  : controller = TextEditingController.fromValue(
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
