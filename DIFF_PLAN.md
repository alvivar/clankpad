# Diff View Redesign — Living Plan

Working document for the diff-view redesign. Phase 1 is shipped; Phases 2–3
remain as the forward queue. The plan / decisions sections are preserved as
the audit trail of what was agreed before implementing.

## Status

| Phase | Scope                                                      | State                   |
| ----- | ---------------------------------------------------------- | ----------------------- |
| 1     | Unified line-level diff, bigger overlay, no cache, no deps | ✅ Shipped              |
| 2     | Word-level intra-line highlighting; side-by-side toggle    | ⏳ Not started          |
| 3     | Per-hunk accept/reject; minimap                            | 💤 Deferred until asked |

## Phase 1 — Shipped

### What landed

| File                            | Change  | LOC                                                               |
| ------------------------------- | ------- | ----------------------------------------------------------------- |
| `lib/services/text_diff.dart`   | **new** | 75                                                                |
| `test/text_diff_test.dart`      | **new** | 112 (13 tests)                                                    |
| `lib/widgets/ai_diff_view.dart` | rewrite | 273 (was 314; net −41, but with substantially more functionality) |

- `editor_screen.dart`, providers, session schema: **untouched**. `AiDiffView`
  constructor surface preserved exactly.
- `flutter analyze`: clean.
- `flutter test`: 13/13 pass.

### Behavioural changes from previous diff view

- Side-by-side panes (`Before` / `After`) replaced by a single unified column.
- Each line carries a marker glyph (`+` / `-` / ` `) and a full-row background
  tint by op kind. Lines that didn't change are shown in full (no collapsing).
- Card size: `680 × 420 px` cap → `LayoutBuilder` → `SizedBox(w * 0.9, h * 0.85)`
  relative to the editor area. Bigger, but still a card-on-overlay, not a modal.
- Header switches `"Proposed AI edit"` ↔ `"Insert"` when `editTarget.isEmpty`,
  falling out of the LCS naturally (all-inserts) with no special branch.
- A single outer `SelectionArea` wraps the row list so cross-line copy works
  without per-row `SelectableText`.

### Discovered during implementation

Issues the plan didn't anticipate, caught in GPT post-implementation review:

- **CRLF mismatch on Windows.** File load uses raw `readAsString()`, so a
  CRLF-terminated original would never match the LF-only stream from the AI —
  every "unchanged" line would have read as modified because of the trailing
  `\r`. Fixed in `_lines()` by normalising `\r\n` and lone `\r` to `\n` before
  splitting. Normalisation is display/diff-only; the editor's text buffer is
  untouched. Regression tests added (CRLF and lone CR cases).
- This is the only deviation from the agreed plan; everything else shipped
  as designed.

## Phase 2 — Word-level + side-by-side toggle (not started)

Notes for when we pick this up:

- **Word-level diff** would re-run a Myers-style diff at token granularity on
  each `(delete_i, insert_i)` adjacent pair, then render the changed runs with
  a stronger background tint inside the existing red/green line backgrounds.
  Token boundary heuristic: split on whitespace + punctuation, or use grapheme
  clusters — TBD.
- **Side-by-side toggle** is the harder half. The wrapped-line / row-height
  alignment problem (the reason we skipped side-by-side in Phase 1) doesn't
  go away. Options when revisiting:
  - Disable wrap in side-by-side mode only (horizontal scroll, code-editor
    style). Acceptable since the toggle is opt-in.
  - Measure each line and force the corresponding line on the other side
    to match. Complex; defer.
- Wiring: a single toggle button next to the status chip. Persist user
  preference in session? Probably yes, key `diffLayout: 'unified' | 'split'`.

## Phase 3 — Per-hunk accept/reject; minimap (deferred)

Only revisit if Phase 2 actually gets used and the user asks. Adds non-trivial
state (per-hunk decisions feed into the final `proposed` text mutation), and
the minimap is purely cosmetic.

---

## Audit trail (decisions made before implementing)

### Goal

Replace the previous side-by-side plain-text diff overlay (which was "useless
for bigger texts") with a unified `git diff`-style view that highlights
line-level changes inline.

### Pain points addressed

1. **No highlighting** — user had to eyeball-diff to find what changed.
2. **No alignment** — corresponding lines drifted apart as panes scrolled.
3. **Card too small** for non-trivial selections.

### Decisions

| #   | Question                         | Decision                                                                                                                                                       |
| --- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Layout for Phase 1               | **Unified only.** Side-by-side deferred to Phase 2 toggle.                                                                                                     |
| 2   | Long runs of unchanged context   | **Show all lines, no collapsing.** Be explicit.                                                                                                                |
| 3   | Sizing                           | **Bigger overlay**, not full modal. Keep lightweight feel.                                                                                                     |
| 4   | Line numbers                     | **Skip for Phase 1.**                                                                                                                                          |
| 5   | Diff algorithm                   | **Plain LCS via DP**, pure Dart, in-house. No new deps.                                                                                                        |
| 6   | Diff granularity                 | **Line-level only.** Word-level deferred to Phase 2.                                                                                                           |
| 7   | Cache strategy                   | **None.** `AiDiffView` stays stateless; recompute in `build()`. (Revised from "memoise in stateful widget" during style review — see GPT style pass #3 below.) |
| 8   | Streaming behaviour              | Recompute on every chunk. No throttling unless profiling shows lag.                                                                                            |
| 9   | Insert mode (empty `editTarget`) | Naturally falls out of LCS — all proposed lines become `insert` ops. Header label switches from "Proposed AI edit" to "Insert".                                |

### Architecture (as built)

#### `lib/services/text_diff.dart`

Pure-Dart line diff. No Flutter imports.

```dart
enum DiffKind { keep, delete, insert }
typedef DiffOp = ({DiffKind kind, String line});
List<DiffOp> diffLines(String before, String after);
```

- LCS dynamic programming, O(N·M) time and memory. For 300 × 300 lines that's
  ~90k cell updates per recompute; streamed at ~30 chunks/sec, ~2.7M cell
  ops/sec — comfortably under a frame budget. Above ~1000 lines, expect
  visible jank; swap to Myers O(ND) at that point.
- DP table is a flat `List<int>.filled((N+1)*(M+1), 0)`. `Int32List` would be
  premature for our scale.
- Tie-break in backtrack favours inserts (strict `>` for "go up"), so deletes
  precede inserts in forward order — matches `diff -u` / `git diff`.
- `_lines()` helper normalises `\r\n` / lone `\r` to `\n` before splitting,
  and treats the empty string as zero lines (avoiding the
  `''.split('\n') == ['']` phantom-line trap).

#### `lib/widgets/ai_diff_view.dart`

Public surface unchanged. **`StatelessWidget`** — recompute `diffLines()`
directly in `build()`. A cache layer would add `StatefulWidget` ceremony to
save work only on incidental rebuilds (focus / theme), while the structural
per-chunk cost is unchanged. Not worth it until profiling says otherwise.

```
AiDiffView (StatelessWidget)
└── build():
    LayoutBuilder → SizedBox(w * 0.90, h * 0.85)
    └── Material card
        ├── Header row: title + status chip
        ├── Divider
        ├── Expanded
        │   └── SelectionArea
        │       └── SingleChildScrollView
        │           └── Column of _buildDiffRow(context, op)
        ├── Divider
        └── Action row: Reject / Accept
```

`_buildDiffRow(context, op)` is a private top-level function — no state,
single call site, class would be ceremony. Renders a 16 px marker column
(`+` / `-` / ` ` in ASCII, no U+2212) plus the line content, with a full-row
background tint by op kind.

Sizing uses tight `SizedBox(width, height)`, not `ConstrainedBox(maxWidth, maxHeight)`,
so the inner `Expanded` scroll region has a bounded height. For short diffs
the card has extra blank space at the bottom — acceptable trade-off for
predictable sizing and a "bigger overlay" feel.

### Validation (Phase 1, completed)

- [x] Unit tests for `diffLines` — 13 cases: empty / identical / single-line
      change / disjoint hunks / trailing newline / op ordering / pure insert
      / pure delete / CRLF / lone CR.
- [x] `flutter analyze` clean.
- [x] GPT review of the diff before user sign-off.
- [ ] **User manual smoke**: small (5-line) / medium (50-line) / large
      (300-line) edits, plus insert mode. Pending user launch.

### GPT review checklist applied

**Technical pass:**

- [x] #1 Line-split edge case: `_lines()` helper, not raw `split('\n')`.
- [x] #2 No cache — see style pass below.
- [x] #3 LCS perf back-of-envelope honest (~90k cells / chunk for 300 lines,
      fine; jank expected above ~1000 lines).
- [x] #4 ASCII `-` marker, not U+2212.
- [x] #5 `SizedBox(width, height)`, not `ConstrainedBox(maxWidth/maxHeight)`,
      so `Expanded` inside the card behaves.
- [x] #6 Single outer `SelectionArea` + plain `Text` per row, not per-row
      `SelectableText`.
- [x] **Post-impl #7** CRLF normalisation in `_lines()` — caught in
      post-implementation review, not in the plan.

**Style pass** (simple / readable / every-line-justified, abstractions only
when essential):

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
- [x] `LayoutBuilder` kept — it's the idiomatic way to size relative to
      available constraints; the two multiplications aren't the cost.
