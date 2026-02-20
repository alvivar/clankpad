import 'package:flutter/material.dart';

import '../models/editor_tab.dart';

class EditorArea extends StatelessWidget {
  final EditorTab tab;
  final bool readOnly;

  const EditorArea({
    super.key,
    required this.tab,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surface,
      child: TextField(
        // Keyed by tab ID so Flutter creates a fresh widget (fresh scroll
        // position, fresh cursor blink) each time a different tab becomes active.
        key: ValueKey(tab.id),
        controller: tab.controller,
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
