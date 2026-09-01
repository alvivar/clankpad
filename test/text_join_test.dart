import 'package:clankpad/services/text_join.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('joinLines', () {
    test('empty text stays empty', () {
      expect(joinLines(''), '');
    });

    test('single line stays unchanged', () {
      expect(joinLines('hello'), 'hello');
    });

    test('trailing whitespace is stripped', () {
      expect(joinLines('hello   '), 'hello');
    });

    test('joins lines within a paragraph', () {
      expect(joinLines('Something like\nthis.'), 'Something like this.');
    });

    test('joins punctuation literally', () {
      expect(
        joinLines('Something like this      \n.'),
        'Something like this .',
      );
    });

    test('preserves one blank line', () {
      expect(joinLines('a\n\nb'), 'a\n\nb');
    });

    test('preserves runs of blank lines', () {
      expect(joinLines('a\n\n\n\nb'), 'a\n\n\n\nb');
    });

    test('emits whitespace-only separators empty', () {
      expect(joinLines('a\n   \nb'), 'a\n\nb');
    });

    test(
      'keeps first-line indentation and strips continuation indentation',
      () {
        expect(joinLines('  one  \n   two'), '  one two');
      },
    );

    test('keeps tab indentation on the first line', () {
      expect(joinLines('\tone\ntwo'), '\tone two');
    });

    test('keeps indentation independently for each paragraph', () {
      expect(joinLines('a\nb\n\n  c\n  d'), 'a b\n\n  c d');
    });

    test('preserves spaces inside a line', () {
      expect(joinLines('a  b\nc'), 'a  b c');
    });

    test('preserves one trailing newline', () {
      expect(joinLines('abc\n'), 'abc\n');
    });

    test('preserves multiple trailing newlines', () {
      expect(joinLines('abc\n\n'), 'abc\n\n');
    });

    test('preserves a leading newline', () {
      expect(joinLines('\nfoo'), '\nfoo');
    });

    test('whitespace-only text becomes empty', () {
      expect(joinLines('   '), '');
    });

    test('normalises CRLF line endings', () {
      expect(joinLines('a\r\nb'), 'a b');
    });

    test('normalises lone-CR line endings', () {
      expect(joinLines('a\rb'), 'a b');
    });

    test('preserves CRLF paragraph breaks', () {
      expect(joinLines('a\r\n\r\nb'), 'a\r\n\r\nb');
    });

    test('leaves an already-joined CRLF document unchanged', () {
      expect(joinLines('line1\r\n\r\nline2'), 'line1\r\n\r\nline2');
    });

    test('joins CRLF lines while preserving paragraph breaks', () {
      expect(joinLines('a\r\nb\r\n\r\nc'), 'a b\r\n\r\nc');
    });

    test('is idempotent for multiple paragraphs', () {
      const input = 'a\nb\n\n  c\n  d';
      expect(joinLines(joinLines(input)), joinLines(input));
    });
  });
}
