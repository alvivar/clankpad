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

/// A single line operation in the unified diff. Named record — a class would
/// be ceremony for two immutable fields with no methods.
typedef DiffOp = ({DiffKind kind, String line});

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

Use a plain `List<int>.filled((N+1)*(M+1), 0)` for the DP table, indexed
manually. Flat is enough — reaching for `Int32List` would be premature
optimisation for diffs that cap at a few hundred lines.

### Rewrite: `lib/widgets/ai_diff_view.dart`

Public surface unchanged: same constructor, same shortcuts, same accept /
reject callbacks. **Stays `StatelessWidget`** — recompute `diffLines()`
directly in `build()`. A cache layer would add `StatefulWidget` ceremony to
save work only on incidental rebuilds (focus / theme), while the structural
per-chunk cost is unchanged. Not worth it until profiling says otherwise.

```
AiDiffView (StatelessWidget)
└── build():
    LayoutBuilder → SizedBox(w * 0.90, h * 0.85)
    └── Material card
        ├── Header row: title + status chip (unchanged)
        ├── Divider
        ├── Expanded
        │   └── SelectionArea
        │       └── SingleChildScrollView
        │           └── Column of _buildDiffRow(context, op)
        ├── Divider
        └── Action row: Reject / Accept (unchanged)
```

### `_buildDiffRow(context, op)` helper

A private top-level function, not a widget class — it has no state, is used in
one place, and a class would be ceremony. Renders:

```
[ marker column ][ content column ]
```

- **Marker column**: fixed width (~20 px), shows `+`, `-`, or ` `, coloured.
  ASCII `-`, matching git — safe for copy/search, no font-fallback surprises.
- **Content column**: plain `Text`, wrap enabled, monospace, padded. The outer
  `SelectionArea` makes cross-line selection work without per-row
  `SelectableText` overhead.
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
| `lib/widgets/ai_diff_view.dart` | **rewrite** — unified view + sizing                     | net ≈ −100 (delete pane plumbing, no cache) |
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

Technical pass:

- [x] #1 Line-split edge case: `_lines()` helper, not raw `split('\n')`.
- [x] #2 No cache — see style pass below.
- [x] #3 LCS perf back-of-envelope honest (~90k cells / chunk for 300 lines,
      fine; jank expected above ~1000 lines).
- [x] #4 ASCII `-` marker, not U+2212.
- [x] #5 `SizedBox(width, height)`, not `ConstrainedBox(maxWidth/maxHeight)`,
      so `Expanded` inside the card behaves.
- [x] #6 Single outer `SelectionArea` + plain `Text` per row, not per-row
      `SelectableText`.

Style pass (simple / readable / every-line-justified, abstractions only when
essential):

- [x] `DiffOp` is a `typedef ({DiffKind kind, String line})`, not a class —
      no methods, no equality contract needed.
- [x] DP table is plain `List<int>.filled(...)`, not `Int32List` —
      premature optimisation dropped.
- [x] `AiDiffView` stays `StatelessWidget`, no diff cache — the cache only
      saved incidental rebuild work, at the cost of `StatefulWidget` ceremony.
- [x] Per-row rendering is a private function `_buildDiffRow(context, op)`,
      not a `_DiffLineRow` widget class — stateless, single call site,
      class would be ceremony.
- [x] `text_diff.dart` kept as a separate file — justified for testability
      and to keep UI free of algorithm code.
- [x] `_lines()` helper kept — names a non-obvious Dart edge case, used
      twice, one line.
- [x] `LayoutBuilder` kept — it’s the idiomatic way to size relative to
      available constraints; the two multiplications aren’t the cost.
