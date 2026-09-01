# Ctrl+J — Join Lines (unwrap hard-wrapped text)

Adds a `Ctrl+J` shortcut that joins hard-wrapped lines into one line per
paragraph. Motivation: text pasted from a terminal arrives hard-wrapped with
trailing spaces on every line.

**Files**
- NEW `lib/services/text_join.dart`
- NEW `test/text_join_test.dart`
- MOD `lib/models/intents.dart`
- MOD `lib/screens/editor_screen.dart`

**Baseline** — worktree clean, `flutter analyze` clean, `flutter test` green
(`test/text_diff_test.dart`, 13 tests). Confirm before task 1.

**Risk** — low overall. Task 2 edits `editor_screen.dart` (~1100 lines), so it
is the serialized/sensitive one.

Line numbers are approximate; re-locate by the quoted anchors.

---

## Confirmed semantics (settled with the user — do NOT relitigate)

1. A line containing only whitespace counts as **blank** and separates
   paragraphs. This matches the app's existing definition in
   `_paragraphRangeAt` (`editor_screen.dart` ~129): *"A paragraph is a maximal
   run of consecutive non-blank lines"*, which also tests `.trim().isEmpty`.
2. Strip **both** leading and trailing whitespace per line when joining, but
   the **first line of each paragraph keeps its indentation**.
3. **No punctuation heuristics.** `"Something like this   \n."` →
   `"Something like this ."` (space before the period) is CORRECT and accepted.
4. **Blank-line runs are preserved one-for-one** (3 blank lines stay 3), but are
   emitted as **truly empty** lines — the stray spaces they carry are the
   terminal artefact this feature removes. This also makes the function
   idempotent.
5. Lines within a paragraph are joined with a **single space**.
6. Runs of spaces **inside** a line are left untouched; only line boundaries are
   trimmed.

Selection behaviour:
- Selection present → operate on exactly the selected substring (even if it
  starts/ends mid-line); the result stays selected.
- No selection → operate on the whole document; the caret is **kept where it
  was** (clamped), NOT moved to the end and NOT selecting the whole file.

---

## Task 1 — `joinLines` pure function + tests

**Where** — new files `lib/services/text_join.dart`, `test/text_join_test.dart`.
Mirrors the existing `lib/services/text_diff.dart` + `test/text_diff_test.dart`
pair: one top-level function, no class, no typedef, no options object.

**Problem** — the join logic must be unit-testable without a widget, and must
not add algorithm code to the already-large `editor_screen.dart`.

**Fix** — create `lib/services/text_join.dart` containing exactly this:

```dart
/// Joins hard-wrapped lines into one line per paragraph.
///
/// A paragraph is a maximal run of non-blank lines — matching
/// `_paragraphRangeAt` in editor_screen.dart. A whitespace-only line is blank
/// and separates paragraphs. Blank lines are preserved one-for-one so spacing
/// survives, but are emitted empty: the stray trailing spaces they carry are
/// the terminal artefact this feature exists to remove.
String joinLines(String text) {
  // Normalise line endings. The CRLF pass must run FIRST: the lone-CR pass
  // would otherwise turn each "\r\n" into two newlines, inventing a paragraph
  // break. Lone-CR documents are rare, but never split at all without it.
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = StringBuffer();
  var inParagraph = false;

  for (final (i, line) in lines.indexed) {
    final content = line.trim();
    // Every line but the first gets a separator: a space continues the current
    // paragraph, a newline starts or ends one.
    if (i > 0) out.write(inParagraph && content.isNotEmpty ? ' ' : '\n');
    if (content.isEmpty) {
      inParagraph = false;
      continue;
    }
    // A paragraph's first line keeps its indentation; continuations go flush.
    if (!inParagraph) {
      out.write(line.substring(0, line.length - line.trimLeft().length));
      inParagraph = true;
    }
    out.write(content);
  }
  return out.toString();
}
```

**Invariant to preserve if you refactor** — the two `replaceAll` calls are an
ordered pair; swapping them corrupts every CRLF line break into a paragraph
break. The `i > 0` guard is equally load-bearing.
It cannot be replaced with `out.isNotEmpty`: a document starting with a blank
line would then lose its leading newline (`"\nfoo"` → `"foo"`). Verified.

**Do not** build paragraphs with `list[last] += ' $content'` — Dart strings are
immutable, so that is O(n²) on a large single-paragraph document (the exact
pasted-terminal case this feature targets). The `StringBuffer` is deliberate.

**Risk** — low (new file, no callers yet).

**Verify** — `flutter test test/text_join_test.dart`. Write `test/text_join_test.dart`
covering at least this table (all expected values hand-verified against the
algorithm above):

| # | input | expected |
|---|---|---|
| 1 | `''` | `''` |
| 2 | `'hello'` | `'hello'` |
| 3 | `'hello   '` | `'hello'` |
| 4 | `'Something like\nthis.'` | `'Something like this.'` |
| 5 | `'Something like this      \n.'` | `'Something like this .'` |
| 6 | `'a\n\nb'` | `'a\n\nb'` |
| 7 | `'a\n\n\n\nb'` | `'a\n\n\n\nb'` |
| 8 | `'a\n   \nb'` | `'a\n\nb'` |
| 9 | `'  one  \n   two'` | `'  one two'` |
| 10 | `'\tone\ntwo'` | `'\tone two'` |
| 11 | `'a\nb\n\n  c\n  d'` | `'a b\n\n  c d'` |
| 12 | `'a  b\nc'` | `'a  b c'` |
| 13 | `'abc\n'` | `'abc\n'` |
| 14 | `'abc\n\n'` | `'abc\n\n'` |
| 15 | `'\nfoo'` | `'\nfoo'` |
| 16 | `'   '` | `''` |
| 17 | `'a\r\nb'` | `'a b'` |
| 18 | `'a\rb'` | `'a b'` |
| 19 | `'a\r\n\r\nb'` | `'a\n\nb'` |

Plus an **idempotence** test: `joinLines(joinLines(x)) == joinLines(x)` for the
multi-paragraph example (#11).

Name the tests descriptively (the existing `text_diff_test.dart` is the style
reference). Group them if it reads better; the table is the required coverage,
not a required layout.

---

## Task 2 — wire `Ctrl+J` into the editor

**Where** — `lib/models/intents.dart` and `lib/screens/editor_screen.dart`.

**Problem** — the pure function needs an intent, a key binding, an action, and
must go inert while an AI overlay has focus.

**Fix** — four edits, following the existing `MoveLineUpIntent` precedent
exactly:

1. `lib/models/intents.dart` — add alongside the other intent classes:

```dart
class JoinLinesIntent extends Intent {
  const JoinLinesIntent();
}
```

2. `lib/models/intents.dart` — add to the `aiOverlayBlockedShortcuts` const map
   (so Ctrl+J does nothing while the prompt/diff overlay is focused, matching
   every other app-level Ctrl shortcut):

```dart
  SingleActivator(LogicalKeyboardKey.keyJ, control: true):
      DoNothingAndStopPropagationIntent(),
```

3. `lib/screens/editor_screen.dart` — in the `Shortcuts` map (~983-1001, where
   `MoveLineUpIntent` is bound):

```dart
        SingleActivator(LogicalKeyboardKey.keyJ, control: true):
            JoinLinesIntent(),
```

4. `lib/screens/editor_screen.dart` — in the `Actions` map (~1027-1032, next to
   the `MoveLineUpIntent` entry):

```dart
          JoinLinesIntent: CallbackAction<JoinLinesIntent>(
            onInvoke: (_) => _joinLines(),
          ),
```

5. `lib/screens/editor_screen.dart` — add the handler next to `_moveLines`
   (~167), and import `../services/text_join.dart`:

```dart
  /// Joins hard-wrapped lines within the selection, or the whole document when
  /// there is no selection. See `joinLines` for the paragraph rules.
  void _joinLines() {
    if (!_editorFocusNode.hasFocus || _editorReadOnly) return;
    final controller = _state.activeTab.controller;
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid) return;

    final hadSelection = !selection.isCollapsed;
    final start = hadSelection ? selection.start : 0;
    final end = hadSelection ? selection.end : text.length;
    final source = text.substring(start, end);
    final joined = joinLines(source);
    if (joined == source) return; // no-op: don't dirty the tab or push undo

    final newText = text.replaceRange(start, end, joined);
    controller.value = TextEditingValue(
      text: newText,
      // Selection mode leaves the result selected. Whole-document mode keeps
      // the caret where it was rather than selecting the entire file, which
      // would make one stray keystroke wipe the document.
      selection: hadSelection
          ? TextSelection(baseOffset: start, extentOffset: start + joined.length)
          : TextSelection.collapsed(
              offset: selection.baseOffset.clamp(0, newText.length),
            ),
    );
  }
```

**Invariants** (this task wires into Flutter's text/undo internals — pin these,
verify rather than trust the wiring):
- **Single undo step.** A single `controller.value = ...` assignment is one
  value change, which `EditableText`'s `UndoHistory` records as one entry, so
  one `Ctrl+Z` reverts the whole join. Do **not** split it into multiple
  assignments. (`UndoHistory` coalesces changes within
  `_kThrottleDuration = 500ms` — `flutter/lib/src/widgets/undo_history.dart:105`
  — so a join within 500ms of typing may merge with it. Accepted; do not add
  custom undo infrastructure.)
- **No-op guard.** `if (joined == source) return;` must stay before the
  assignment, so an already-joined document does not mark the tab dirty or push
  an undo entry.
- **Guards match `_moveLines`** — `hasFocus`, `_editorReadOnly`,
  `selection.isValid`. Do not add a redundant `text.isEmpty` guard (the no-op
  guard already covers it) or `.clamp()` on `selection.start/end` (guaranteed
  in-bounds by `isValid`).

**Risk** — low-medium. Large shared file; the edits are additive and local.

**Verify** — `flutter analyze` + `flutter test`. Manual smoke test is the
user's (see below); do not attempt to drive the GUI.

---

## Sequencing

1. **Task 1** — pure function + tests (new files, no integration risk).
2. **Task 2** — wiring (touches the large shared `editor_screen.dart`).

Strictly sequential; task 2 depends on task 1's function existing.

**Gate (applied after every task):**
- `flutter analyze` → must report no issues
- `flutter test` → all tests green (13 existing + the new join tests)

A native `flutter build windows` is **not** part of the gate: these are
pure-Dart changes with no plugin/native surface, so `analyze` is the meaningful
compile check.

---

## Manual smoke test (user, after commit)

1. Paste terminal text with trailing spaces → `Ctrl+J` with no selection →
   joins per paragraph, blank lines preserved, caret stays put.
2. Select two lines mid-paragraph → `Ctrl+J` → only that fragment joins, result
   stays selected.
3. `Ctrl+Z` once → the whole join reverts in one step.
4. `Ctrl+J` twice → second press changes nothing (idempotent, tab not dirtied).
5. Open the AI prompt overlay (`Ctrl+K`) → `Ctrl+J` does nothing.

---

## Out of scope

- **Line-ending preservation.** `Ctrl+J` emits LF, so joining a selection inside
  a CRLF file yields mixed endings that persist on save. This is **pre-existing**
  app behaviour (AI edits already insert LF into CRLF documents, and
  `editor_state.dart:343` does `readAsString()` with no normalisation). A proper
  "preserve document line endings" pass is a separate task.
- Punctuation-aware joining (rejected — requirement 3).
- Collapsing runs of spaces inside a line (rejected — requirement 6).
- Custom undo boundaries to defeat the 500ms coalescing window.
- Any change to `SHUTDOWN_PLAN.md`'s scope — that is a separate, unexecuted plan.
