import 'package:flutter/services.dart';

/// Moves the line(s) covered by [value]'s selection up (`direction` -1) or
/// down (+1) past the adjacent line. Multi-line selections move as a block.
/// Returns null when the move is a no-op.
///
/// Line endings: `\r\n` and `\n` are separators, never line content. The block
/// and its neighbour swap places around the separator between them. Separators
/// inside a multi-line block travel with it; those outside the exchanged span
/// stay where they are. A uniform LF or CRLF document therefore stays uniform,
/// and a mixed one is not normalized. A lone `\r` is ordinary content.
///
/// The terminal-newline status never changes. The empty position after a
/// terminal newline is not a line: nothing moves below it, and a caret there
/// does not move. In a document without a terminal newline, a move that would
/// make an empty line the last line is a no-op, because that would add one.
///
/// Covered lines: a non-empty selection ending at the start of a line does not
/// include that line. Selection endpoints keep their direction and shift with
/// the block; an endpoint after the block's trailing separator maps to the
/// start of the line that follows the moved block (or the block's end at EOF).
TextEditingValue? moveLines(TextEditingValue value, int direction) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid || text.isEmpty) return null;

  final selectionEnd = !selection.isCollapsed && text[selection.end - 1] == '\n'
      ? selection.end - 1
      : selection.end;
  final blockStart = _lineStart(text, selection.start);
  final blockEnd = _contentEnd(text, selectionEnd);
  if (blockStart == text.length) return null; // after a terminal newline
  final block = text.substring(blockStart, blockEnd);

  final int replaceStart;
  final int replaceEnd;
  final String replacement;
  final int delta;
  final int followingLineStart;
  if (direction < 0) {
    if (blockStart == 0) return null;
    final previousEnd = _contentEnd(text, blockStart - 1);
    final previousStart = _lineStart(text, previousEnd);
    final previous = text.substring(previousStart, previousEnd);
    // An empty previous line would become the unterminated last line.
    if (blockEnd == text.length && previous.isEmpty) return null;
    final separator = text.substring(previousEnd, blockStart);
    replaceStart = previousStart;
    replaceEnd = blockEnd;
    replacement = '$block$separator$previous';
    delta = -(previous.length + separator.length);
    followingLineStart = previousStart + block.length + separator.length;
  } else {
    if (blockEnd == text.length) return null;
    final nextStart = text.indexOf('\n', blockEnd) + 1;
    if (nextStart == text.length) return null; // after a terminal newline
    final nextEnd = _contentEnd(text, nextStart);
    // A block ending in an empty line would become the unterminated end.
    final blockEndsEmpty = block.isEmpty || block.endsWith('\n');
    if (nextEnd == text.length && blockEndsEmpty) return null;
    final next = text.substring(nextStart, nextEnd);
    final separator = text.substring(blockEnd, nextStart);
    replaceStart = blockStart;
    replaceEnd = nextEnd;
    replacement = '$next$separator$block';
    delta = next.length + separator.length;
    // The moved block now ends at nextEnd, followed by next's old separator.
    followingLineStart = nextEnd == text.length
        ? nextEnd
        : text.indexOf('\n', nextEnd) + 1;
  }

  // An endpoint past blockEnd selected the block's trailing separator, which
  // can have another length (or not exist) at the destination.
  int map(int offset) =>
      offset <= blockEnd ? offset + delta : followingLineStart;

  return TextEditingValue(
    text: text.replaceRange(replaceStart, replaceEnd, replacement),
    selection: selection.copyWith(
      baseOffset: map(selection.baseOffset),
      extentOffset: map(selection.extentOffset),
    ),
  );
}

int _lineStart(String text, int offset) =>
    offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

// End of the line's content: before its `\n`, or before `\r\n`.
int _contentEnd(String text, int offset) {
  final newline = text.indexOf('\n', offset);
  if (newline == -1) return text.length;
  return newline > 0 && text[newline - 1] == '\r' ? newline - 1 : newline;
}
