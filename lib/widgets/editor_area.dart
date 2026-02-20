import 'package:flutter/material.dart';

import '../models/editor_tab.dart';

class EditorArea extends StatelessWidget {
  final EditorTab tab;
  final bool readOnly;
  // Persistent FocusNode supplied by EditorScreen so that focus can be
  // explicitly restored after popups and diffs are dismissed.
  final FocusNode? focusNode;

  const EditorArea({
    super.key,
    required this.tab,
    this.readOnly = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surface,
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
    );
  }
}
