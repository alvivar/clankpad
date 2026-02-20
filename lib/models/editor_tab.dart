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

  // Drives only the ● dot in the tab chip. Updated by the controller listener
  // in EditorState — never triggers a full EditorState rebuild.
  final ValueNotifier<bool> isDirtyNotifier;

  EditorTab({
    required this.id,
    this.filePath,
    required this.title,
    this.savedContent = '',
    String initialContent = '',
  })  : controller = TextEditingController(text: initialContent),
        isDirtyNotifier = ValueNotifier<bool>(false);

  bool get isDirty => isDirtyNotifier.value;

  // Called by EditorState when this tab is removed from the list.
  void dispose() {
    controller.dispose();
    isDirtyNotifier.dispose();
  }
}
