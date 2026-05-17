# Diff View Redesign — Phase 1 Plan

## Goal

Replace the current side-by-side plain-text diff overlay (which is "useless
for bigger texts") with a unified `git diff`-style view that highlights
line-level changes inline.

## Context

**Current implementation** (`lib/widgets/ai_diff_view.dart`, 314 LOC):

- Two plain-text panes side-by-side, left = `editTarget` (original selection),
  right = `_diffProposed` (AI output).
- No line correspondence, no highlighting, no scroll sync.
- 680 × 420 px max cap.
- Streams in: chunk arrives → `setState` appends to `_diffProposed` → view
  rebuilds.

**Pain points** (in priority order):

1. No highlighting — user must eyeball-diff to find what changed.
2. No alignment — corresponding lines drift apart as panes scroll.
3. Card too small for non-trivial selections.

## Decisions

| #   | Question                         | Decision                                                                                                                        |
| --- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Layout for Phase 1               | **Unified only.** Side-by-side deferred to Phase 2 toggle.                                                                      |
| 2   | Long runs of unchanged context   | **Show all lines, no collapsing.** Be explicit.                                                                                 |
| 3   | Sizing                           | **Bigger overlay**, not full modal. Keep lightweight feel.                                                                      |
| 4   | Line numbers                     | **Skip for Phase 1.**                                                                                                           |
| 5   | Diff algorithm                   | **Plain LCS via DP**, pure Dart, in-house. No new deps.                                                                         |
| 6   | Diff granularity                 | **Line-level only.** Word-level deferred to Phase 2.                                                                            |
| 7   | Cache strategy                   | Memoise by `(editTarget, proposed)` identity in a stateful widget.                                                              |
| 8   | Streaming behaviour              | Recompute on every chunk. No throttling unless profiling shows lag.                                                             |
| 9   | Insert mode (empty `editTarget`) | Naturally falls out of LCS — all proposed lines become `insert` ops. Header label switches from "Proposed AI edit" to "Insert". |

## Architecture

### New file: `lib/services/text_diff.dart`

Pure-Dart line diff. No Flutter imports. Unit-testable.

```dart
enum DiffKind { keep, delete, insert }

class DiffOp {
  final DiffKind kind;
  final String line;   // single line, no trailing newline
  const DiffOp(this.kind, this.line);
}

/// Computes a line-level diff of [before] vs [after] using LCS DP.
///
/// Splits each input on '\n'. Returns a sequential list of operations:
/// - keep:   line is identical in both
/// - delete: line is in [before] only
/// - insert: line is in [after]  only
///
/// LCS order is canonical: deletes precede inserts at any divergence point,
/// matching `diff -u` / `git diff` conventions.
List<DiffOp> diffLines(String before, String after);
```

**Splitting edge case** (GPT review #1): use

```dart
List<String> _lines(String s) => s.isEmpty ? const [] : s.split('\n');
```

not `s.split('\n')` directly. In Dart `''.split('\n') == ['']`, which would
produce a bogus empty `keep`/`delete` for insert mode.

**Complexity & implementation** (GPT review #3): O(N·M) time and memory.
For 300 × 300 lines, that’s 90k cell updates per recompute. Streamed at ~30
chunks/sec that’s 2.7M cell ops/sec — comfortable. Above 1000 lines, expect
visible jank; swap to Myers O(ND) if it becomes a problem in practice.

Use a flat `Int32List` of size `(N+1)*(M+1)` for the DP table, not
`List<List<int>>`. Same algorithmic cost, ~2x less memory, contiguous layout,
less GC pressure when the table is reallocated per streamed chunk.

### Rewrite: `lib/widgets/ai_diff_view.dart`

Public surface unchanged: same constructor, same shortcuts, same accept /
reject callbacks. The widget becomes a `StatefulWidget` so we can cache the
diff result.

```
AiDiffView (StatefulWidget)
├── _AiDiffViewState
│   ├── _cachedDiff: List<DiffOp>?
│   ├── _cachedKey: (String, String)?
│   └── _diff() → recomputes only when key changes
└── build():
    Material card
    ├── Header row: title + status chip (unchanged)
    ├── Divider
    ├── Expanded
    │   └── SingleChildScrollView
    │       └── Column of _DiffLineRow
    ├── Divider
    └── Action row: Reject / Accept (unchanged)
```

### `_DiffLineRow` widget

One per `DiffOp`. Renders:

```
[ marker column ][ content column ]
```

- **Marker column**: fixed width (~20 px), shows `+`, `-`, or ` `, coloured.
  ASCII `-` (not U+2212) per GPT review #4 — matches git, safe for copy / search,
  no font-fallback surprises.
- **Content column**: plain `Text`, wrap enabled, monospace, padded. Wrap the
  whole diff column in a single `SelectionArea` (GPT review #6) — lighter than
  per-row `SelectableText` and gives correct cross-line selection.
- **Background**: full-row tint —
  - `keep` → no tint
  - `delete` → red bg (`errorContainer.withValues(alpha: 0.20)`)
  - `insert` → green bg (`_green.withValues(alpha: 0.15)`)

### Sizing

Replace the `ConstrainedBox(maxWidth: 680, maxHeight: 420)` with:

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final w = constraints.maxWidth  * 0.90;
    final h = constraints.maxHeight * 0.85;
    return SizedBox(
      width:  w,
      height: h,
      child: _DiffCard(...),
    );
  },
)
```

**Tight, not max-only** (GPT review #5): use `SizedBox(width: w, height: h)`,
not `ConstrainedBox(maxWidth/maxHeight)`. The card should fill the allocated
space for a consistent “bigger overlay” feel; `Expanded` inside the card needs
a bounded parent height to behave. For short diffs the card has extra blank
space at the bottom — acceptable trade-off for predictable sizing.

Centered alignment unchanged (`Align(alignment: Alignment.topCenter, ...)`
already in place). Bump the outer top padding from 12 px to ~24 px so the
larger card has breathing room.

### Caching the diff

Inside `_AiDiffViewState`:

```dart
List<DiffOp> _diff() {
  final key = (widget.editTarget, widget.proposed);
  if (key != _cachedKey) {
    _cachedKey  = key;
    _cachedDiff = diffLines(widget.editTarget, widget.proposed);
  }
  return _cachedDiff!;
}
```

`build()` calls `_diff()` once. Streaming chunk arrival → parent rebuilds
this widget with a new `proposed` String → Dart record equality on the tuple
detects the change by value → recompute.

**Note** (GPT review #2): this cache prevents redundant recomputes within a
single frame (e.g. if `build()` ran twice for an unrelated reason like focus
change or theme rebuild). It does **not** reduce the per-chunk diff cost —
that’s structural: every chunk genuinely changes `proposed` and we genuinely
need a fresh diff. If streaming cost ever becomes a real problem, the
mitigation is throttling chunk delivery upstream, not caching.

### Insert mode

When `editTarget.isEmpty`:

- `diffLines('', proposed)` returns all `insert` ops naturally — no special
  branch in the algorithm.
- The card title switches from `"Proposed AI edit"` to `"Insert"`.

### Header / footer (unchanged)

- Title text + streaming chip in header.
- Reject (Ctrl+Backspace) and Accept (Ctrl+Enter) buttons in footer.
- `Shortcuts` / `Actions` / `Focus` plumbing unchanged.

## Files touched

| File                            | Change                                                  | Est. LOC                         |
| ------------------------------- | ------------------------------------------------------- | -------------------------------- |
| `lib/services/text_diff.dart`   | **new** — LCS line-diff                                 | +60                              |
| `lib/widgets/ai_diff_view.dart` | **rewrite** — unified view + cache + sizing             | net ≈ −80 (delete pane plumbing) |
| `README.md` / feature docs      | update user-facing diff description if behavior changes | +small                           |

No changes to `editor_screen.dart`, providers, or session schema. The widget
constructor surface stays identical.

## Validation steps

1. **Unit test for `diffLines`** (new `test/text_diff_test.dart`):
   - empty before → all inserts
   - empty after → all deletes
   - identical → all keeps
   - single line changed in middle of long unchanged region → 1 delete + 1
     insert flanked by keeps
   - multiple disjoint hunks
   - line-ending edge cases (trailing newline, missing trailing newline)
2. `flutter analyze` clean.
3. Manual: small edit (5 lines), medium (50 lines), large (300 lines) — verify
   readability and absence of jank during streaming.
4. Manual: insert mode (Ctrl+K with empty selection) — verify "Insert" header
   and all-green rendering.
5. GPT review of the diff before commit.

## Out of scope (Phase 2+)

- Word-level highlighting inside delete / insert line pairs.
- Side-by-side / unified toggle.
- Per-hunk accept / reject.
- Minimap / overview ruler.
- Line numbers (selection-relative or file-relative).
- Hunk collapsing of long unchanged runs (deliberately rejected per decision #2).

## Estimated effort

~1 focused pass:

- 20 min `text_diff.dart` + unit tests
- 30 min `ai_diff_view.dart` rewrite
- 10 min sizing & manual smoke test
- 10 min GPT review + adjustments
- 5 min README / feature-doc update

## GPT review checklist applied

- [x] #1 Line-split edge case: `_lines()` helper, not raw `split('\n')`.
- [x] #2 Cache wording clarified — prevents redundant frame rebuilds, does
      not reduce per-chunk streaming cost.
- [x] #3 LCS perf back-of-envelope honest (~90k cells / chunk for 300 lines,
      fine; jank expected above ~1000 lines). Use flat `Int32List` for DP table.
- [x] #4 ASCII `-` marker, not U+2212.
- [x] #5 `SizedBox(width, height)`, not `ConstrainedBox(maxWidth/maxHeight)`,
      so `Expanded` inside the card behaves.
- [x] #6 Single outer `SelectionArea` + plain `Text` per row, not per-row
      `SelectableText`.
