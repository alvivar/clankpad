import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AiPromptPopup extends StatefulWidget {
  final VoidCallback onDismiss;
  final ValueChanged<String> onSubmit;

  const AiPromptPopup({
    super.key,
    required this.onDismiss,
    required this.onSubmit,
  });

  @override
  State<AiPromptPopup> createState() => _AiPromptPopupState();
}

class _AiPromptPopupState extends State<AiPromptPopup> {
  final _promptController = TextEditingController();
  final _textFieldFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Request focus after the frame so the TextField is fully laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFieldFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _textFieldFocusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final prompt = _promptController.text.trim();
    // An empty prompt just dismisses — no AI call needed.
    if (prompt.isEmpty) {
      widget.onDismiss();
      return;
    }
    widget.onSubmit(prompt);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // A local Shortcuts layer blocks the root app shortcuts while the popup
    // is open. Only the 6 root-registered combos are listed here —
    // Ctrl+C/V/X/A/Z are handled internally by EditableText and never reach
    // the root Shortcuts layer regardless, so they need no special treatment.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.keyO, control: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
            DoNothingAndStopPropagationIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            DoNothingAndStopPropagationIntent(),
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              color: colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                // Focus wraps the TextField to intercept Enter/Escape.
                // Key events bubble up from the focused TextField to this Focus,
                // so we never need to focus the outer node directly.
                child: Focus(
                  onKeyEvent: (node, event) {
                    // Only act on initial key-down to avoid double-firing on repeat.
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;

                    // Enter (without Shift) → submit.
                    if (event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed) {
                      _submit();
                      return KeyEventResult.handled;
                    }

                    // Escape → dismiss with no action.
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      widget.onDismiss();
                      return KeyEventResult.handled;
                    }

                    // Shift+Enter and everything else (including Ctrl+C/V/Z)
                    // pass through to the inner TextField unchanged.
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _promptController,
                    focusNode: _textFieldFocusNode,
                    maxLines: null, // allows Shift+Enter newlines
                    style: TextStyle(fontSize: 14, color: colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText:
                          'Edit instruction… (Enter to submit, Shift+Enter for newline, Esc to dismiss)',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    cursorWidth: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
