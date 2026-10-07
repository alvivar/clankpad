/// A deliberately simple Markdown scanner for live styling in the editor.
///
/// It is not CommonMark. It recognises a small set of forms and leaves
/// everything else plain:
///
/// - Block forms are line-based and may be indented. In order: fenced code,
///   thematic breaks (rules), ATX headings, block quotes, list items.
/// - Inline forms (code spans, emphasis, strikethrough, links) never span
///   lines. Code spans hide everything inside them from the other forms.
///
/// Offsets are UTF-16 code units of the scanned text, as in [TextSelection].
library;

import 'dart:math';

enum MarkdownKind {
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  bold,
  italic,
  strikethrough,
  code,
  quote,
  listMarker,
  link,

  /// Markdown syntax characters, shown dimmed.
  delimiter,
}

/// A styled range [start, end) of the scanned text. Runs may overlap: a
/// heading line contains its `#` delimiter, bold text inside it, and so on.
typedef MarkdownRun = ({int start, int end, MarkdownKind kind});

List<MarkdownRun> scanMarkdown(String text) => _Scanner(text).scan();

const _tab = 0x09;
const _carriageReturn = 0x0D;
const _space = 0x20;
const _bang = 0x21;
const _hash = 0x23;
const _openParen = 0x28;
const _closeParen = 0x29;
const _star = 0x2A;
const _plus = 0x2B;
const _dash = 0x2D;
const _dot = 0x2E;
const _zero = 0x30;
const _nine = 0x39;
const _greaterThan = 0x3E;
const _openBracket = 0x5B;
const _backslash = 0x5C;
const _closeBracket = 0x5D;
const _underscore = 0x5F;
const _backtick = 0x60;
const _tilde = 0x7E;

const _headings = [
  MarkdownKind.heading1,
  MarkdownKind.heading2,
  MarkdownKind.heading3,
  MarkdownKind.heading4,
  MarkdownKind.heading5,
  MarkdownKind.heading6,
];

bool _isBlank(int c) => c == _space || c == _tab;

bool _isPunctuation(int c) =>
    (c >= _bang && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= _openBracket && c <= _backtick) ||
    (c >= 0x7B && c <= _tilde);

/// An unmatched run of `*`, `_` or `~` that may still open emphasis.
class _Opener {
  _Opener(this.start, this.length);
  final int start;
  int length;
}

class _Scanner {
  _Scanner(this.text);

  final String text;
  final _runs = <MarkdownRun>[];

  // The open code fence, if any.
  int _fenceChar = 0;
  int _fenceLength = 0;
  int _fenceStart = 0;

  List<MarkdownRun> scan() {
    var start = 0;
    while (true) {
      final newline = text.indexOf('\n', start);
      final next = newline == -1 ? text.length : newline;
      final end = next > start && text.codeUnitAt(next - 1) == _carriageReturn
          ? next - 1
          : next;
      _line(start, end);
      if (newline == -1) break;
      start = newline + 1;
    }
    // An unclosed fence runs to the end of the text.
    if (_fenceChar != 0) _add(_fenceStart, text.length, MarkdownKind.code);
    return _runs;
  }

  void _add(int start, int end, MarkdownKind kind) {
    if (end > start) _runs.add((start: start, end: end, kind: kind));
  }

  int _char(int i) => text.codeUnitAt(i);

  /// The end of the run of [char] starting at [i], before [end].
  int _runEnd(int i, int end, int char) {
    while (i < end && _char(i) == char) {
      i++;
    }
    return i;
  }

  int _skipBlanks(int i, int end) {
    while (i < end && _isBlank(_char(i))) {
      i++;
    }
    return i;
  }

  /// Styles the line [start, end), which excludes its line terminator.
  void _line(int start, int end) {
    final first = _skipBlanks(start, end);

    if (_fenceChar != 0) {
      final runEnd = _runEnd(first, end, _fenceChar);
      if (runEnd - first >= _fenceLength && _skipBlanks(runEnd, end) == end) {
        _add(first, end, MarkdownKind.delimiter);
        _add(_fenceStart, end, MarkdownKind.code);
        _fenceChar = 0;
      }
      return;
    }
    if (first == end) return;

    final c = _char(first);
    if (c == _backtick || c == _tilde) {
      final runEnd = _runEnd(first, end, c);
      // A backtick fence's info string cannot contain backticks, so a line
      // such as ```code``` stays an inline code span.
      if (runEnd - first >= 3 &&
          (c == _tilde || _indexOf(_backtick, runEnd, end) == -1)) {
        _fenceChar = c;
        _fenceLength = runEnd - first;
        _fenceStart = first;
        _add(first, end, MarkdownKind.delimiter);
        return;
      }
    }

    if (_isRule(first, end)) {
      _add(first, end, MarkdownKind.delimiter);
      return;
    }

    if (c == _hash) {
      final hashesEnd = _runEnd(first, end, _hash);
      final level = hashesEnd - first;
      if (level <= 6 && hashesEnd < end && _isBlank(_char(hashesEnd))) {
        _add(first, end, _headings[level - 1]);
        _add(first, hashesEnd, MarkdownKind.delimiter);
        _inline(hashesEnd, end);
        return;
      }
    }

    if (c == _greaterThan) {
      _add(first, first + 1, MarkdownKind.delimiter);
      _add(first + 1, end, MarkdownKind.quote);
      _inline(first + 1, end);
      return;
    }

    final markerEnd = _listMarkerEnd(first, end);
    if (markerEnd != -1) {
      _add(first, markerEnd, MarkdownKind.listMarker);
      var contentStart = _skipBlanks(markerEnd, end);
      if (_isTaskBox(contentStart, end)) {
        _add(contentStart, contentStart + 3, MarkdownKind.listMarker);
        contentStart += 3;
      }
      _inline(contentStart, end);
      return;
    }

    _inline(first, end);
  }

  /// Three or more `-`, `*` or `_` (the same one), optionally separated by
  /// blanks, and nothing else.
  bool _isRule(int first, int end) {
    final c = _char(first);
    if (c != _dash && c != _star && c != _underscore) return false;
    var count = 0;
    for (var i = first; i < end; i++) {
      final d = _char(i);
      if (d == c) {
        count++;
      } else if (!_isBlank(d)) {
        return false;
      }
    }
    return count >= 3;
  }

  /// The end of a `-`, `*`, `+` or `1.`/`1)` marker followed by a blank,
  /// or -1.
  int _listMarkerEnd(int first, int end) {
    final c = _char(first);
    var markerEnd = first + 1;
    if (c >= _zero && c <= _nine) {
      while (markerEnd < end &&
          markerEnd - first < 9 &&
          _char(markerEnd) >= _zero &&
          _char(markerEnd) <= _nine) {
        markerEnd++;
      }
      if (markerEnd == end) return -1;
      final delimiter = _char(markerEnd);
      if (delimiter != _dot && delimiter != _closeParen) return -1;
      markerEnd++;
    } else if (c != _dash && c != _star && c != _plus) {
      return -1;
    }
    return markerEnd < end && _isBlank(_char(markerEnd)) ? markerEnd : -1;
  }

  /// `[ ]`, `[x]` or `[X]`, followed by a blank or the end of the line.
  bool _isTaskBox(int i, int end) {
    if (i + 3 > end) return false;
    final mark = _char(i + 1);
    return _char(i) == _openBracket &&
        (mark == _space || mark == 0x78 || mark == 0x58) &&
        _char(i + 2) == _closeBracket &&
        (i + 3 == end || _isBlank(_char(i + 3)));
  }

  /// Styles inline forms in [start, end), all on one line.
  void _inline(int start, int end) {
    final openers = <int, List<_Opener>>{
      _star: [],
      _underscore: [],
      _tilde: [],
    };
    final brackets = <int>[];
    // Backtick run lengths known to have no closing run later on the line,
    // and whether no `)` is left. A failed backtick search still scans the
    // rest of the line once per distinct run length, which bounds a line at
    // O(n * sqrt(n)); every other search is consumed or remembered.
    final unclosedTicks = <int>{};
    var noCloseParen = false;

    var i = start;
    while (i < end) {
      final c = _char(i);
      if (c == _backslash && i + 1 < end && _isPunctuation(_char(i + 1))) {
        i += 2;
      } else if (c == _backtick) {
        final runEnd = _runEnd(i, end, c);
        final length = runEnd - i;
        final close = unclosedTicks.contains(length)
            ? -1
            : _closingTicks(runEnd, end, length);
        if (close == -1) {
          unclosedTicks.add(length);
          i = runEnd;
        } else {
          _add(i, close + length, MarkdownKind.code);
          _add(i, runEnd, MarkdownKind.delimiter);
          _add(close, close + length, MarkdownKind.delimiter);
          i = close + length;
        }
      } else if (c == _star || c == _underscore || c == _tilde) {
        final runEnd = _runEnd(i, end, c);
        _emphasis(openers[c]!, c, i, runEnd, start, end);
        i = runEnd;
      } else if (c == _openBracket) {
        brackets.add(i);
        i++;
      } else if (c == _closeBracket && brackets.isNotEmpty) {
        final open = brackets.removeLast();
        var close = -1;
        if (!noCloseParen && i + 1 < end && _char(i + 1) == _openParen) {
          close = _indexOf(_closeParen, i + 2, end);
          noCloseParen = close == -1;
        }
        if (close == -1) {
          i++;
        } else {
          _add(open, open + 1, MarkdownKind.delimiter);
          _add(open + 1, i, MarkdownKind.link);
          _add(i, close + 1, MarkdownKind.delimiter);
          brackets.clear(); // links do not nest
          i = close + 1;
        }
      } else {
        i++;
      }
    }
  }

  int _indexOf(int char, int from, int end) {
    for (var i = from; i < end; i++) {
      if (_char(i) == char) return i;
    }
    return -1;
  }

  /// The start of the next backtick run of exactly [length] in [from, end),
  /// or -1.
  int _closingTicks(int from, int end, int length) {
    var i = _indexOf(_backtick, from, end);
    while (i != -1) {
      final runEnd = _runEnd(i, end, _backtick);
      if (runEnd - i == length) return i;
      i = _indexOf(_backtick, runEnd, end);
    }
    return -1;
  }

  /// Matches the delimiter run [runStart, runEnd) of [char] against
  /// [openers], then keeps what is left of it as an opener if it can open.
  void _emphasis(
    List<_Opener> openers,
    int char,
    int runStart,
    int runEnd,
    int lineStart,
    int lineEnd,
  ) {
    var length = runEnd - runStart;
    if (char == _tilde && length != 2) return;

    final before = runStart > lineStart ? _char(runStart - 1) : _space;
    final after = runEnd < lineEnd ? _char(runEnd) : _space;
    var canOpen = !_isBlank(after);
    var canClose = !_isBlank(before);
    if (char == _underscore) {
      // No intraword underscores: snake_case, file_name.txt.
      canOpen = canOpen && (_isBlank(before) || _isPunctuation(before));
      canClose = canClose && (_isBlank(after) || _isPunctuation(after));
    }

    var start = runStart;
    if (canClose) {
      while (length > 0 && openers.isNotEmpty) {
        final opener = openers.last;
        final used = char == _tilde ? 2 : min(2, min(opener.length, length));
        final contentStart = opener.start + opener.length;
        _add(contentStart - used, contentStart, MarkdownKind.delimiter);
        _add(start, start + used, MarkdownKind.delimiter);
        _add(
          contentStart,
          start,
          char == _tilde
              ? MarkdownKind.strikethrough
              : used == 2
              ? MarkdownKind.bold
              : MarkdownKind.italic,
        );
        opener.length -= used;
        if (opener.length == 0) openers.removeLast();
        start += used;
        length -= used;
      }
    }
    if (canOpen && length > 0) openers.add(_Opener(start, length));
  }
}
