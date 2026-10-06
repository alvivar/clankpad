import 'package:clankpad/services/move_lines.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CRLF stays a delimiter', () {
    test('across an unterminated last line', () {
      expect(_move('a\r\nb', 0, 0, 1), ('b\r\na', 3, 3));
      expect(_move('b\r\na', 3, 3, -1), ('a\r\nb', 0, 0));
    });

    test('with a terminal newline', () {
      expect(_move('a\r\nb\r\n', 0, 0, 1), ('b\r\na\r\n', 3, 3));
      expect(_move('a\r\nb\r\n', 4, 4, -1), ('b\r\na\r\n', 1, 1));
    });
  });

  test('LF documents move the same way', () {
    expect(_move('a\nb', 1, 1, 1), ('b\na', 3, 3));
    expect(_move('a\nb\n', 2, 2, -1), ('b\na\n', 0, 0));
  });

  test('mixed separators stay in place by position', () {
    expect(_move('a\r\nb\nc', 0, 0, 1), ('b\r\na\nc', 3, 3));
    expect(_move('a\r\nb\nc', 5, 5, -1), ('a\r\nc\nb', 3, 3));
  });

  test('reversed multi-line selection moves as a block', () {
    // Block "a\r\nb" (base after b, extent at a) moves below c.
    expect(_move('a\r\nb\r\nc', 4, 0, 1), ('c\r\na\r\nb', 7, 3));
    expect(_move('c\r\na\r\nb', 7, 3, -1), ('a\r\nb\r\nc', 4, 0));
  });

  test('a selection ending at a line start excludes that line', () {
    expect(_move('a\r\nb\r\nc', 0, 3, 1), ('b\r\na\r\nc', 3, 6));
  });

  group('a selected trailing separator maps to the moved line end', () {
    test('missing at the destination (EOF)', () {
      expect(_move('a\r\nb', 0, 3, 1), ('b\r\na', 3, 4));
      expect(_move('a\r\nb', 3, 0, 1), ('b\r\na', 4, 3));
    });

    test('shorter or longer at the destination', () {
      expect(_move('a\r\nb\nc', 0, 3, 1), ('b\r\na\nc', 3, 5));
      expect(_move('a\nb\r\nc', 0, 2, 1), ('b\na\r\nc', 2, 5));
      expect(_move('a\nb\r\nc', 2, 0, 1), ('b\na\r\nc', 5, 2));
    });

    test('moving up', () {
      expect(_move('a\nb\r\nc', 2, 5, -1), ('b\na\r\nc', 0, 2));
      expect(_move('a\nb\r\nc', 5, 2, -1), ('b\na\r\nc', 2, 0));
      expect(_move('a\nb\r\n', 2, 5, -1), ('b\na\r\n', 0, 2));
    });
  });

  test('empty lines move when they stay inside the document', () {
    expect(_move('\na\nb', 0, 0, 1), ('a\n\nb', 2, 2));
  });

  group('boundaries are no-ops', () {
    test('an empty line cannot become an unterminated last line', () {
      expect(_move('\na', 0, 0, 1), isNull);
      expect(_move('\na', 1, 1, -1), isNull);
      expect(_move('\r\na', 0, 0, 1), isNull);
      expect(_move('\r\na', 2, 2, -1), isNull);
      // Block "x" + empty line, selected up to the start of "a".
      expect(_move('x\n\na', 0, 3, 1), isNull);
      expect(_move('x\r\n\r\na', 0, 5, 1), isNull);
    });

    test('first line up and last line down', () {
      expect(_move('a\r\nb', 0, 0, -1), isNull);
      expect(_move('a\r\nb', 3, 3, 1), isNull);
    });

    test('nothing moves below a terminal newline', () {
      expect(_move('a\r\nb\r\n', 3, 3, 1), isNull);
      // Every line selected, ending at the terminal newline.
      expect(_move('a\r\nb\r\n', 0, 6, 1), isNull);
    });

    test('a caret after a terminal newline does not move', () {
      expect(_move('a\r\nb\r\n', 6, 6, -1), isNull);
      expect(_move('a\nb\n', 4, 4, -1), isNull);
    });
  });
}

(String, int, int)? _move(String text, int base, int extent, int direction) {
  final moved = moveLines(
    TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
    ),
    direction,
  );
  if (moved == null) return null;
  return (moved.text, moved.selection.baseOffset, moved.selection.extentOffset);
}
