import 'package:clankpad/services/text_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diffLines', () {
    test('both empty → no ops', () {
      expect(diffLines('', ''), isEmpty);
    });

    test('empty before → all inserts (insert mode)', () {
      expect(diffLines('', 'a\nb'), [
        (kind: DiffKind.insert, line: 'a'),
        (kind: DiffKind.insert, line: 'b'),
      ]);
    });

    test('empty after → all deletes', () {
      expect(diffLines('a\nb', ''), [
        (kind: DiffKind.delete, line: 'a'),
        (kind: DiffKind.delete, line: 'b'),
      ]);
    });

    test('identical → all keeps', () {
      expect(diffLines('a\nb\nc', 'a\nb\nc'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.keep, line: 'b'),
        (kind: DiffKind.keep, line: 'c'),
      ]);
    });

    test('single-line change in the middle of a long context', () {
      expect(diffLines('a\nx\nc', 'a\ny\nc'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.delete, line: 'x'),
        (kind: DiffKind.insert, line: 'y'),
        (kind: DiffKind.keep, line: 'c'),
      ]);
    });

    test('multiple disjoint hunks', () {
      expect(diffLines('a\nx\nc\ny\ne', 'a\nC\nc\nD\ne'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.delete, line: 'x'),
        (kind: DiffKind.insert, line: 'C'),
        (kind: DiffKind.keep, line: 'c'),
        (kind: DiffKind.delete, line: 'y'),
        (kind: DiffKind.insert, line: 'D'),
        (kind: DiffKind.keep, line: 'e'),
      ]);
    });

    test('trailing newline becomes a trailing empty line', () {
      // 'a\n' splits into ['a', ''] — preserving the empty line is correct;
      // dropping it would lose the round-trip property for diff/apply.
      expect(diffLines('a\n', 'a\n'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.keep, line: ''),
      ]);
    });

    test('deletes precede inserts at a divergence point', () {
      expect(diffLines('x', 'y'), [
        (kind: DiffKind.delete, line: 'x'),
        (kind: DiffKind.insert, line: 'y'),
      ]);
    });

    test('reordering: delete then insert at front, keep at end', () {
      // a→b at line 0 must read as "delete a, insert b, keep tail" — not
      // "insert b, delete a", which would be technically valid LCS but
      // contrary to git convention.
      expect(diffLines('a\nz', 'b\nz'), [
        (kind: DiffKind.delete, line: 'a'),
        (kind: DiffKind.insert, line: 'b'),
        (kind: DiffKind.keep, line: 'z'),
      ]);
    });

    test('pure insertion inside an unchanged block', () {
      expect(diffLines('a\nb', 'a\nNEW\nb'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.insert, line: 'NEW'),
        (kind: DiffKind.keep, line: 'b'),
      ]);
    });

    test('pure deletion inside an unchanged block', () {
      expect(diffLines('a\nGONE\nb', 'a\nb'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.delete, line: 'GONE'),
        (kind: DiffKind.keep, line: 'b'),
      ]);
    });

    test('CRLF vs LF: lines match after normalisation', () {
      // On Windows, file load is raw — a CRLF original would otherwise never
      // match the AI's LF-only output, falsely flagging every line as changed.
      expect(diffLines('a\r\nb', 'a\nb'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.keep, line: 'b'),
      ]);
    });

    test('lone CR is normalised too (legacy classic-Mac line endings)', () {
      expect(diffLines('a\rb', 'a\nb'), [
        (kind: DiffKind.keep, line: 'a'),
        (kind: DiffKind.keep, line: 'b'),
      ]);
    });
  });
}
