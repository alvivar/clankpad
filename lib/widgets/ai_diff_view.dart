import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/intents.dart';

/// Inline diff overlay shown after the AI returns a result.
///
/// Displays the original [editTarget] alongside the [proposed] replacement so
/// the user can review before committing. Keyboard shortcuts per spec:
///   Accept → Tab  or  Ctrl+Enter
///   Reject → Escape
///
/// A local [Shortcuts] layer intercepts those keys before they reach the root
/// layer. App-level shortcuts (Ctrl+N, Ctrl+W, …) are also blocked while this
/// overlay is focused.
class AiDiffView extends StatelessWidget {
  final String editTarget;
  final String proposed;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  // Owned by EditorScreen so focus can be driven externally.
  final FocusNode focusNode;

  const AiDiffView({
    super.key,
    required this.editTarget,
    required this.proposed,
    required this.onAccept,
    required this.onReject,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        // ── Diff actions ──────────────────────────────────────────────────
        SingleActivator(LogicalKeyboardKey.tab): AcceptDiffIntent(),
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            AcceptDiffIntent(),
        SingleActivator(LogicalKeyboardKey.escape): RejectDiffIntent(),

        // ── Block app-level shortcuts (same list as AiPromptPopup) ────────
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
      child: Actions(
        actions: {
          AcceptDiffIntent: CallbackAction<AcceptDiffIntent>(
            onInvoke: (_) => onAccept(),
          ),
          RejectDiffIntent: CallbackAction<RejectDiffIntent>(
            onInvoke: (_) => onReject(),
          ),
        },
        // Focus is driven externally: EditorScreen calls focusNode.requestFocus()
        // in a post-frame callback once the diff view is mounted, and returns
        // focus to _editorFocusNode after accept / reject.
        child: Focus(
          focusNode: focusNode,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 680,
                  maxHeight: 420,
                ),
                child: _DiffCard(
                  editTarget: editTarget,
                  proposed: proposed,
                  onAccept: onAccept,
                  onReject: onReject,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Card layout ───────────────────────────────────────────────────────────────

class _DiffCard extends StatelessWidget {
  final String editTarget;
  final String proposed;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _DiffCard({
    required this.editTarget,
    required this.proposed,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Proposed AI edit',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: colorScheme.onSurface,
              ),
            ),
          ),

          const Divider(height: 1),

          // Side-by-side before/after panes.
          //
          // IntrinsicHeight is used intentionally here. The goal is for both
          // panes to be the same height and for the card to shrink-wrap its
          // content up to the 420px cap set by the outer ConstrainedBox.
          // IntrinsicHeight measures the taller pane's content height, which
          // is then clamped by Flexible's max constraint; each Expanded _DiffPane
          // receives that capped height, and SingleChildScrollView inside scrolls
          // when content exceeds it.
          //
          // A ConstrainedBox with a fixed max-height on each pane cannot replicate
          // this: the card would always be at least that tall, even for a two-line
          // diff. No IntrinsicHeight-free layout simultaneously content-sizes the
          // card, equalises pane heights, and enables per-pane scrolling.
          //
          // Flutter's quadratic-intrinsic-measurement warning applies to trees
          // where IntrinsicHeight appears inside a scrolling list or other hot
          // layout path. Here it wraps a static subtree of ~20 nodes, evaluated
          // once per AI response — the performance impact is negligible.
          Flexible(
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _DiffPane(
                      label: 'Before',
                      text: editTarget,
                      labelColor: colorScheme.error,
                      backgroundColor: colorScheme.errorContainer.withValues(
                        alpha: 0.25,
                      ),
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: colorScheme.outlineVariant,
                  ),
                  Expanded(
                    child: _DiffPane(
                      label: 'After',
                      text: proposed,
                      labelColor: _greenColor(context),
                      backgroundColor: _greenColor(
                        context,
                      ).withValues(alpha: 0.10),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 1),

          // Action row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  child: const Text('Reject  (Esc)'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onAccept,
                  child: const Text('Accept  (Tab)'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Returns a green that works in both light and dark themes.
  static Color _greenColor(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? const Color(0xFF81C784) // Material green 300
        : const Color(0xFF388E3C); // Material green 700
  }
}

// ── Single pane ───────────────────────────────────────────────────────────────

class _DiffPane extends StatelessWidget {
  final String label;
  final String text;
  final Color labelColor;
  final Color backgroundColor;

  const _DiffPane({
    required this.label,
    required this.text,
    required this.labelColor,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pane label
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: labelColor,
                letterSpacing: 0.5,
              ),
            ),
          ),

          // Scrollable text content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                text.isEmpty ? '(empty)' : text,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 13,
                  height: 1.5,
                  color: text.isEmpty
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
