// Line-level diff for the AI edit overlay. Pure Dart, no Flutter dependency.
// Feeds the unified diff renderer in `lib/widgets/ai_diff_view.dart`.

enum DiffKind { keep, delete, insert }

/// A single line operation in the unified diff. A record (not a class):
/// two immutable fields, no methods, structural equality is exactly what
/// we want for tests.
typedef DiffOp = ({DiffKind kind, String line});

/// Splits a string into lines for diff comparison.
///
/// - Empty input → no lines (avoids Dart's `''.split('\n') == ['']` trap).
/// - CRLF and lone CR normalised to LF so Windows-loaded originals match the
///   LF-only stream from the AI. Comparison-only; editor buffer untouched.
List<String> _lines(String s) => s.isEmpty
    ? const []
    : s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// Unified line-level diff of [before] vs [after].
///
/// LCS dynamic programming, O(N·M). Comfortable for selections of a few
/// hundred lines, even recomputed every streamed chunk. Above ~1000 lines
/// expect jank; swap to Myers O(ND) then.
///
/// At a divergence point, deletes precede inserts (`diff -u` / `git diff`
/// convention).
List<DiffOp> diffLines(String before, String after) {
  final a = _lines(before);
  final b = _lines(after);
  final n = a.length;
  final m = b.length;

  // Flat (n+1) × (m+1) LCS table: dp[i*w + j] = LCS length of a[..i], b[..j].
  // Flat List<int> avoids nested-list allocation overhead; Int32List would
  // be premature for the sizes we handle.
  final w = m + 1;
  final dp = List<int>.filled((n + 1) * w, 0);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final idx = i * w + j;
      if (a[i - 1] == b[j - 1]) {
        dp[idx] = dp[idx - w - 1] + 1;
      } else {
        final up = dp[idx - w];
        final left = dp[idx - 1];
        dp[idx] = up >= left ? up : left;
      }
    }
  }

  // Backtrack from (n, m) to (0, 0), emitting ops in reverse order.
  // Tie-break: strict `>` so equal cells fall through to insert, placing
  // deletes before inserts in forward order.
  final out = <DiffOp>[];
  var i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
      out.add((kind: DiffKind.keep, line: a[i - 1]));
      i--;
      j--;
    } else {
      final idx = i * w + j;
      final goUp = j == 0 || (i > 0 && dp[idx - w] > dp[idx - 1]);
      if (goUp) {
        out.add((kind: DiffKind.delete, line: a[i - 1]));
        i--;
      } else {
        out.add((kind: DiffKind.insert, line: b[j - 1]));
        j--;
      }
    }
  }
  return out.reversed.toList(growable: false);
}
