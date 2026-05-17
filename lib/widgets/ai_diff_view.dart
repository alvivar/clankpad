import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/intents.dart';
import '../services/text_diff.dart';

/// Inline diff overlay shown after the AI returns a result.
///
/// Renders a unified line-level diff (`git diff` style) of the original
/// [editTarget] against the [proposed] replacement: deletes in red, inserts in
/// green, unchanged context shown in full. Keyboard shortcuts per spec:
///   Accept → Ctrl+Enter
///   Reject → Ctrl+Backspace
///
/// A local [Shortcuts] layer intercepts those keys before they reach the root
/// layer. App-level shortcuts (Ctrl+N, Ctrl+W, …) are also blocked while this
/// overlay is focused.
class AiDiffView extends StatelessWidget {
  final String editTarget;
  final String proposed;
  final bool isStreaming;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  // Owned by EditorScreen so focus can be driven externally.
  final FocusNode focusNode;

  const AiDiffView({
    super.key,
    required this.editTarget,
    required this.proposed,
    required this.isStreaming,
    required this.onAccept,
    required this.onReject,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            AcceptDiffIntent(),
        SingleActivator(LogicalKeyboardKey.backspace, control: true):
            RejectDiffIntent(),
        ...aiOverlayBlockedShortcuts,
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
          // Larger card than the previous 680×420 cap: a meaningful diff often
          // exceeded those bounds and was cut off. LayoutBuilder + SizedBox
          // gives a consistent "bigger overlay" feel sized to the editor area
          // rather than a fixed pixel cap. Tight (not max-only) constraints so
          // the inner Expanded scroll region has a bounded height.
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: LayoutBuilder(
                builder: (context, c) => SizedBox(
                  width: c.maxWidth * 0.90,
                  height: c.maxHeight * 0.85,
                  child: _DiffCard(
                    editTarget: editTarget,
                    proposed: proposed,
                    isStreaming: isStreaming,
                    onAccept: onAccept,
                    onReject: onReject,
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

// ── Card layout ───────────────────────────────────────────────────────────────

class _DiffCard extends StatelessWidget {
  final String editTarget;
  final String proposed;
  final bool isStreaming;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _DiffCard({
    required this.editTarget,
    required this.proposed,
    required this.isStreaming,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isInsert = editTarget.isEmpty;
    // Recomputed on every parent rebuild — i.e. once per streamed chunk.
    // O(N·M) LCS; cheap for our scale. See `lib/services/text_diff.dart`.
    final ops = diffLines(editTarget, proposed);

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Text(
                  isInsert ? 'Insert' : 'Proposed AI edit',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                _StatusChip(isStreaming: isStreaming),
              ],
            ),
          ),

          const Divider(height: 1),

          // Unified diff body. A single SelectionArea wraps the whole list so
          // text selection works across rows without per-row SelectableText
          // overhead (which would also break cross-line selection).
          Expanded(
            child: SelectionArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final op in ops) _buildDiffRow(context, op)],
                ),
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
                  child: const Text('Reject  (Ctrl+Backspace)'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onAccept,
                  child: const Text('Accept  (Ctrl+Enter)'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Unified diff row ──────────────────────────────────────────────────────────

/// Renders a single diff line: a fixed-width marker column ('+'/'-'/' ') plus
/// the line content, with a full-row background tint by op kind.
///
/// Top-level function, not a widget class: it has no state, no per-instance
/// configuration, and is called from one place. A class would be ceremony.
Widget _buildDiffRow(BuildContext context, DiffOp op) {
  final colorScheme = Theme.of(context).colorScheme;
  final green = _greenLine(context);

  final (marker, fg, bg) = switch (op.kind) {
    DiffKind.keep => (
      ' ',
      colorScheme.onSurfaceVariant,
      const Color(0x00000000),
    ),
    DiffKind.delete => (
      '-',
      colorScheme.error,
      colorScheme.errorContainer.withValues(alpha: 0.20),
    ),
    DiffKind.insert => ('+', green, green.withValues(alpha: 0.15)),
  };

  const baseStyle = TextStyle(
    fontFamily: 'Consolas',
    fontSize: 13,
    height: 1.5,
  );

  return ColoredBox(
    color: bg,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(
              marker,
              style: baseStyle.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              op.line,
              style: baseStyle.copyWith(color: colorScheme.onSurface),
              softWrap: true,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Green that reads well on both light and dark surfaces. Used for both the
/// insert marker glyph and the insert-line background tint.
Color _greenLine(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF81C784) // Material green 300
    : const Color(0xFF388E3C); // Material green 700

// ── Status chip ───────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final bool isStreaming;

  const _StatusChip({required this.isStreaming});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fg = isStreaming ? colorScheme.primary : colorScheme.secondary;
    final bg = isStreaming
        ? colorScheme.primaryContainer.withValues(alpha: 0.6)
        : colorScheme.secondaryContainer.withValues(alpha: 0.6);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          isStreaming ? 'Generating…' : 'Complete',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}
