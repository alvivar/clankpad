# Clankpad — Application Review

**Reviewed:** full Flutter application codebase

- `lib/` application code
- `pubspec.yaml`
- `analysis_options.yaml`
- platform runner shells (`windows/`, `linux/`, `macos/`)
- docs/spec context (`SPEC.md`)

**Priority:** simplicity first, performance second, then organization / idiomatic Dart & Flutter.

**Current status:** `flutter analyze` passes with **no issues**.

---

## Executive summary

This is a **good, intentionally simple Flutter desktop app**.

The strongest parts of the codebase are:

- very small dependency surface
- sensible flat project structure
- careful focus/keyboard handling for desktop
- a good state split that avoids rebuilding the UI on every keystroke
- minimal abstraction around AI providers without overengineering

The main weaknesses are also clear:

- one very large screen file (`EditorScreen`) owns too many responsibilities
- AI model data is passed around as `Map<String, dynamic>` instead of a typed model
- debounced session writes are synchronous on the UI isolate
- there is no test suite yet

Overall, the project already feels lean. The best improvements are the ones that **remove code and reduce moving parts**, not the ones that introduce more architecture.

---

## Overall assessment

### What is already strong

### 1. Simplicity of architecture

The project structure is appropriate for the app size:

- `models/`
- `state/`
- `services/`
- `screens/`
- `widgets/`

That is about the right amount of separation. It avoids both extremes:

- not everything is dumped into one file/folder
- not every concept has its own pattern, layer, or package

This is a **good small Flutter app structure**.

### 2. Good performance-oriented state design

The most important architectural decision in the app is a good one:

- text edits do **not** trigger broad widget rebuilds
- structural changes still use `notifyListeners()`
- tab dirtiness is isolated with `ValueNotifier<bool>`
- session persistence is triggered through a separate change channel

That is a strong design for a text editor. It keeps typing performance safe without introducing state-management complexity.

### 3. Good desktop UX discipline

The code pays attention to desktop-specific issues that many Flutter apps ignore:

- focus restoration
- shortcut handling
- preventing focus theft from icon buttons
- modal overlay shortcut blocking
- explicit tab-switch/editor-focus behavior

This is one of the higher-quality aspects of the app.

### 4. Very small dependency footprint

`pubspec.yaml` is minimal:

- Flutter SDK
- `file_selector`
- default lints

That is excellent for long-term maintenance, startup time, and project clarity.

---

## Highest-priority findings

These are the changes most worth making, in order.

---

## 1. Replace AI model `Map<String, dynamic>` data with a typed model

**Priority:** very high
**Why:** simplifies code and improves correctness
**Files affected:**

- `lib/services/ai_provider.dart`
- `lib/services/pi_provider.dart`
- `lib/services/claude_code_provider.dart`
- `lib/screens/editor_screen.dart`
- `lib/widgets/ai_prompt_popup.dart`

### Problem

AI model data is passed around as `List<Map<String, dynamic>>`.

That creates repeated code like:

- `m['provider']`
- `m['id']`
- `m['name']`
- `m['reasoning'] == true`
- many casts and null checks

This is not just less type-safe; it also makes the code noisier than necessary.

### Why this matters for simplicity

A typed class is actually **simpler** than maps here. It removes:

- string-key lookups
- dynamic casting
- repeated helper logic
- accidental key typos

### Recommendation

Introduce a small immutable model, for example:

```dart
class AiModel {
  final String provider;
  final String id;
  final String name;
  final bool supportsReasoning;

  const AiModel({
    required this.provider,
    required this.id,
    required this.name,
    this.supportsReasoning = false,
  });
}
```

Then replace `List<Map<String, dynamic>>` with `List<AiModel>` throughout.

### Expected result

- less code
- safer refactors
- clearer UI code
- better IDE/autocomplete support

This is the single best cleanup in the codebase because it improves both **simplicity** and **maintainability** without adding architecture.

---

## 2. Make debounced session writes asynchronous

**Priority:** very high
**Why:** protects UI responsiveness
**File:** `lib/services/session_service.dart`

### Problem

The debounced save path uses synchronous file I/O:

- `writeAsStringSync`
- `renameSync`

This work happens on the main isolate.

For small sessions this is usually fine, but a text editor can easily end up with:

- multiple tabs
- large documents
- frequent edits

That means periodic synchronous JSON serialization + disk I/O while the app is otherwise interactive.

### Recommendation

Keep `flushSync()` for shutdown, but make the normal debounced path async.

In practice:

- `_schedule()` can trigger an async write method
- use `await _tmpFile.writeAsString(...)`
- use `await _tmpFile.rename(...)`
- keep errors swallowed/logged as they are now

### Expected result

- lower risk of frame hitches during heavy typing/editing
- same behavior from the user perspective
- no increase in conceptual complexity

This is a clean performance win.

---

## 3. Split `EditorScreen` by responsibility

**Priority:** high
**Why:** improves organization and lowers cognitive load
**File:** `lib/screens/editor_screen.dart` (~1176 lines)

### Problem

`EditorScreen` currently owns too much:

- file open/save/close behavior
- AI prompt lifecycle
- AI streaming / diff accept-reject
- provider switching
- model loading / caching
- prompt history
- search UI behavior
- line movement behavior
- startup notices
- widget tree rendering

The code is not chaotic, but it is **too concentrated**.

### Why this matters for simplicity

A file this large becomes harder to reason about even when the code is good.
The issue is not architecture quality; it is file size and responsibility breadth.

### Recommendation

Split mechanically, not architecturally.

Good low-cost extraction targets:

#### A. AI flow helpers

Move these into a private helper file, extension, or mixin:

- prompt open/dismiss
- submit/cancel
- diff accept/reject
- provider/model/thinking state helpers
- prompt history helpers
- model fetch/cache logic

#### B. File actions

Move:

- open file
- save / save as
- close tab dialog path
- error dialog helpers
- file-name helpers

#### C. Pure text utilities

Move pure functions out of widget state:

- paragraph range helper
- match computation helper

### Expected result

- easier navigation
- smaller review surface for future changes
- less risk when editing unrelated behavior

Important: **do not introduce a new architecture package or pattern for this**. Simple extraction into a couple of private files is enough.

---

## 4. `EditorState.onAnyChange` should be more structured

**Priority:** medium-high
**Why:** correctness and maintainability
**File:** `lib/state/editor_state.dart`

### Problem

`EditorState` exposes a mutable callback field:

```dart
VoidCallback? onAnyChange;
```

This works, but it has drawbacks:

- only one listener can exist safely
- any code can overwrite it
- lifecycle ownership is implicit
- it is less idiomatic than the rest of the app

### Why this matters for simplicity

A raw field looks simple at first, but it creates a hidden contract.
A more explicit mechanism is easier to reason about.

### Recommendation

Keep the overall idea, but make it slightly more formal. Good options:

#### Option A — best balance

Use a dedicated `ValueNotifier<int>` or `ChangeNotifier`-style internal notifier just for “any change”.

#### Option B — minimal change

Keep one listener only, but expose it as a setter and document/assert single assignment.

### Expected result

- clearer ownership
- easier future expansion
- more idiomatic API surface

This is worth improving, but it is less urgent than the model typing and async session write changes.

---

## 5. Add a small test suite

**Priority:** medium-high
**Why:** protects the app’s most important editor behavior
**Current state:** no `test/` directory

### Problem

There are several pieces of logic that are valuable and testable, but currently untested:

- paragraph detection
- search match computation
- tab/session restore behavior
- line move behavior
- editor tab dirty-state transitions
- session JSON behavior

### Recommendation

Do not aim for broad widget-test coverage first. Start with **small unit tests** around pure logic and state behavior.

Best first tests:

1. `EditorState.restoreFromSession()` edge cases
2. search match helper
3. paragraph range helper
4. line move behavior
5. session serialization rules

### Expected result

- protects the editor’s core behavior
- supports future cleanup of `EditorScreen`
- keeps refactors safe

For an editor app, this is a better investment than adding more architecture.

---

## Additional findings

---

## 6. Duplicate blocked-shortcut maps should be shared

**Priority:** medium
**Files:**

- `lib/widgets/ai_prompt_popup.dart`
- `lib/widgets/ai_diff_view.dart`

Both widgets define almost the same shortcut-blocking map using `DoNothingAndStopPropagationIntent()`.

### Why it matters

This is small duplication, but it creates drift risk if shortcuts change.

### Recommendation

Extract a shared `const` map in `lib/models/intents.dart` or a small helper.

### Expected result

- less duplication
- one source of truth for overlay-blocked app shortcuts

---

## 7. `EditorTab.savedContent` should probably be updated through a method

**Priority:** medium
**File:** `lib/models/editor_tab.dart`

### Problem

`savedContent` is mutable and its relationship to `isDirtyNotifier` is managed externally.

That is workable, but it means multiple places must remember the invariant.

### Recommendation

Consider a small method that updates the saved baseline and dirtiness together.

Example shape:

```dart
void markSaved(String content) {
  savedContent = content;
  isDirtyNotifier.value = controller.text != savedContent;
}
```

### Expected result

- fewer invariant leaks
- less repeated code in state logic

Not urgent, but a good cleanup.

---

## 8. Use `async` / `await` instead of `.then()` / `.catchError()` here

**Priority:** medium
**File:** `lib/screens/editor_screen.dart`

Model fetching currently uses chained futures in one place.

### Recommendation

Prefer `async` / `await` for consistency and readability.

### Why

This app mostly uses `async` / `await` already. Keeping one style improves readability, especially in a large stateful screen.

This is a minor cleanup, not a major issue.

---

## 9. `UnmodifiableListView(_tabs)` is recreated on each getter call

**Priority:** low-medium
**File:** `lib/state/editor_state.dart`

This is cheap, but it still allocates a new wrapper each time `tabs` is read.

### Recommendation

If desired, cache the wrapper and invalidate it on structural changes.

### Important note

This is not a high-priority issue. It is much smaller than the synchronous session-write concern.

---

## 10. `EditorArea._spaces()` is non-idiomatic Dart

**Priority:** low
**File:** `lib/widgets/editor_area.dart`

Current code builds spaces with `List.filled(...).join()`.

### Recommendation

Use:

```dart
' ' * count
```

This is clearer and more idiomatic.

Tiny issue, easy win.

---

## 11. Search is simple and acceptable, but may need debouncing for very large files

**Priority:** low
**Files:** search logic in `EditorScreen`

The search implementation recomputes matches on every search-field change. For current scale this is fine.

### Recommendation

Keep it as-is unless large-document performance becomes visible.
If needed later, debounce the **search input**, not the whole editor.

This is a good example of where the current simpler solution is appropriate.

---

## Flutter / Dart idiomatic quality

### Good idiomatic choices already present

- `const` usage is generally good
- small focused widgets for tab bar, diff view, find bar, editor area
- `ValueListenableBuilder` used appropriately for dirty indicators
- lifecycle cleanup is careful
- desktop keyboard handling is deliberate and explicit
- minimal abstraction surface for providers

### Less idiomatic areas

- raw `Map<String, dynamic>` data model use
- mutable callback field for cross-object change subscription
- one oversized `State` class doing too much

These are important, but they are very fixable.

---

## Project-level review

## `pubspec.yaml`

### Good

- very small dependency list
- no unnecessary packages
- no state-management framework overhead

### Minor improvements

- `description: "A new Flutter project."` is still the default and should be replaced
- if desired, add a few extra lint rules in `analysis_options.yaml`, but keep this selective to preserve simplicity

Recommended approach: keep lints lightweight.

---

## `analysis_options.yaml`

Current config just includes `flutter_lints`.

That is fine for this project.

I would **not** add a large custom lint set unless the team wants stricter consistency. If you do add anything, keep it short and high-value.

Good candidates only if wanted:

- `unawaited_futures`
- `directives_ordering`
- `prefer_final_locals`

But this is optional. The current simple setup is defensible.

---

## Platform runner code

The platform folders are mostly stock Flutter runners.

### Notes

- Windows runner has a custom initial window sizing/positioning block, which is reasonable and isolated.
- macOS AppDelegate changes are minimal and appropriate.
- Linux runner appears stock and clean.

No major issues here.

---

## Best things to keep exactly as they are

These parts should be preserved during refactors:

1. **Avoiding rebuilds on every keystroke**
   This is the right call for an editor.

2. **Minimal dependency footprint**
   Very good for a desktop utility app.

3. **Focused widget extraction**
   `FindBar`, `EditorArea`, `EditorTabBar`, `AiDiffView`, and `AiPromptPopup` are useful boundaries.

4. **Provider abstraction size**
   `AiProvider` is small and sufficient. Do not make it more abstract unless needed.

5. **Focus restoration discipline**
   This is one of the app’s quality markers.

---

## Suggested implementation order

### Quick wins

1. Type the AI model data
2. Make debounced session writes async
3. Replace `.then()` / `.catchError()` with `async` / `await`
4. Share the blocked-shortcut map
5. Replace space generation with `' ' * count`

### Next structural pass

6. Split AI-related methods out of `EditorScreen`
7. Split file-related methods out of `EditorScreen`
8. Move pure text helpers into testable utility/state code
9. Slightly formalize the `onAnyChange` contract

### Reliability pass

10. Add a small unit test suite around editor/state/session logic

---

## Final verdict

This is already a **high-quality small Flutter app** with good instincts:

- simple architecture
- strong desktop behavior
- good attention to performance where it matters most
- minimal dependencies

The main opportunity is not to add patterns, but to **reduce friction**:

- type the AI model data
- remove sync writes from the normal edit path
- shrink `EditorScreen`
- add a few targeted tests

If those changes are made, the codebase will become noticeably easier to maintain **without becoming more complicated**.
