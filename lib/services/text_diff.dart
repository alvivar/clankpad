/// Line-level diff for the AI edit overlay.
///
/// Pure Dart, no Flutter dependency. Feeds the unified diff renderer in
/// `lib/widgets/ai_diff_view.dart`.
library;

enum DiffKind { keep, delete, insert }

/// A single line operation in the unified diff. A record (not a class):
/// two immutable fields, no methods, structural equality is exactly what
/// we want for tests.
typedef DiffOp = ({DiffKind kind, String line});

/// Splits a string into lines for comparison, treating the empty string as
/// zero lines and normalising CRLF / CR endings to LF.
///
/// Without the empty-string guard, `''.split('\n') == ['']` would inject a
/// phantom empty line into every insert-mode diff.
///
/// Without normalisation, a CRLF original (typical for files opened from a
/// Windows-saved file) would never match the LF-only text streamed back by
/// the AI — every “unchanged” line would look modified because of a trailing
/// `\r`. Stripping CR is purely a display/comparison concern; the editor's
/// underlying text buffer is untouched.
List<String> _lines(String s) => s.isEmpty
    ? const []
    : s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// Returns a unified line-level diff of [before] vs [after].
///
/// Uses LCS dynamic programming: O(N·M) time and memory. For our scale
/// (selections up to a few hundred lines) this stays well under a frame
/// budget even when recomputed on every streamed chunk. Above ~1000 lines,
/// expect visible jank; swap to Myers O(ND) at that point.
///
/// Op ordering at a divergence point: deletes precede inserts, matching
/// `diff -u` and `git diff` conventions.
List<DiffOp> diffLines(String before, String after) {
  final a = _lines(before);
  final b = _lines(after);
  final n = a.length;
  final m = b.length;

  // Flat (n+1) × (m+1) LCS table: dp[i*w + j] = LCS length of a[..i], b[..j].
  // Flat List<int> avoids the nested-list allocation overhead; reaching for
  // Int32List would be premature for the sizes we handle.
  final w = m + 1;
  final dp = List<int>.filled((n + 1) * w, 0);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      dp[i * w + j] = a[i - 1] == b[j - 1]
          ? dp[(i - 1) * w + (j - 1)] + 1
          : (dp[(i - 1) * w + j] >= dp[i * w + (j - 1)]
                ? dp[(i - 1) * w + j]
                : dp[i * w + (j - 1)]);
    }
  }

  // Backtrack from (n, m) to (0, 0), emitting ops in reverse. The tie-break
  // (strict `>` for "go up") means tied cells fall through to insert; that
  // places deletes before inserts in forward order.
  final out = <DiffOp>[];
  var i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
      out.add((kind: DiffKind.keep, line: a[i - 1]));
      i--;
      j--;
    } else if (j == 0 || (i > 0 && dp[(i - 1) * w + j] > dp[i * w + (j - 1)])) {
      out.add((kind: DiffKind.delete, line: a[i - 1]));
      i--;
    } else {
      out.add((kind: DiffKind.insert, line: b[j - 1]));
      j--;
    }
  }
  return out.reversed.toList(growable: false);
}
