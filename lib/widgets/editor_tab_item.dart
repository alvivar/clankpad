import 'package:flutter/material.dart';

import '../models/editor_tab.dart';

class EditorTabItem extends StatelessWidget {
  final EditorTab tab;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const EditorTabItem({
    super.key,
    required this.tab,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // ValueListenableBuilder rebuilds only this chip when isDirty changes.
    // EditorState.notifyListeners() is never called on keystrokes, so the
    // rest of the tab bar stays untouched.
    return ValueListenableBuilder<bool>(
      valueListenable: tab.isDirtyNotifier,
      builder: (context, isDirty, _) {
        final bgColor = isActive
            ? colorScheme.surface
            : colorScheme.surfaceContainerHighest;
        final fgColor = isActive
            ? colorScheme.onSurface
            : colorScheme.onSurfaceVariant;

        return GestureDetector(
          onTap: onTap,
          child: Container(
            height: 36,
            padding: const EdgeInsets.only(left: 12, right: 4),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                bottom: BorderSide(
                  color: isActive ? colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
                right: BorderSide(color: colorScheme.outlineVariant, width: 1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Dirty indicator dot
                if (isDirty)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text(
                      '●',
                      style: TextStyle(
                        fontSize: 9,
                        color: colorScheme.primary,
                        height: 1,
                      ),
                    ),
                  ),

                // Tab title
                Text(tab.title, style: TextStyle(fontSize: 13, color: fgColor)),

                const SizedBox(width: 6),

                // Close button — ExcludeFocus prevents the IconButton from
                // stealing focus away from the editor on click.
                ExcludeFocus(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 13,
                      icon: Icon(
                        Icons.close,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      tooltip: 'Close tab',
                      onPressed: onClose,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
