import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The find bar shown between the tab bar and the editor when Ctrl+F is active.
///
/// All state (query, matches, index) lives in the parent. This widget is purely
/// presentational: it fires callbacks and the parent calls setState.
class FindBar extends StatelessWidget {
  const FindBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.matchIndex,
    required this.onQueryChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Total number of matches in the document. 0 when the query is empty or
  /// has no matches.
  final int matchCount;

  /// 0-based index of the currently highlighted match. -1 when none.
  final int matchIndex;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasQuery = controller.text.isNotEmpty;
    final hasMatches = matchCount > 0;

    return ColoredBox(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            // Search field — Focus wraps TextField so onKeyEvent fires for
            // the subtree. maxLines: null keeps Enter from being consumed as
            // onSubmitted; we intercept it in onKeyEvent instead.
            Expanded(
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  final key = event.logicalKey;
                  final shift = HardwareKeyboard.instance.isShiftPressed;
                  if (key == LogicalKeyboardKey.escape) {
                    onClose();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.enter && shift) {
                    onPrev();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.enter && !shift) {
                    onNext();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.f3 && shift) {
                    onPrev();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.f3 && !shift) {
                    onNext();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: null,
                  onChanged: onQueryChanged,
                  decoration: const InputDecoration(
                    hintText: 'Find…',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),

            // Match counter — only shown when the field is non-empty.
            if (hasQuery)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  hasMatches ? '${matchIndex + 1} of $matchCount' : 'No results',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            // Previous / next / close — ExcludeFocus so clicks don't steal
            // focus from the search field.
            ExcludeFocus(
              child: IconButton(
                onPressed: hasMatches ? onPrev : null,
                icon: const Icon(Icons.keyboard_arrow_up),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                tooltip: 'Previous (Shift+Enter)',
              ),
            ),
            ExcludeFocus(
              child: IconButton(
                onPressed: hasMatches ? onNext : null,
                icon: const Icon(Icons.keyboard_arrow_down),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                tooltip: 'Next (Enter)',
              ),
            ),
            ExcludeFocus(
              child: IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                tooltip: 'Close (Esc)',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
