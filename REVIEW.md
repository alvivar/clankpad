# Clankpad — Code Review

**Scope:** all 15 Dart files in `lib/` (~4,100 lines) + `SPEC.md`.
**Focus:** simplicity (top priority), performance, idiomatic Dart/Flutter, organization.

---

## Overall verdict

**Solid project — above average for its size.** The architecture is deliberately flat, state boundaries are well-chosen, dependency footprint is minimal (`file_selector` only), and `flutter analyze` is clean.

The codebase has two kinds of issues: a few correctness/performance gaps that matter, and a set of idiomatic Dart/Flutter roughnesses that don't block users but make the code harder to maintain. Both are listed below, prioritized.

---

## 1 — Correctness

### 1.1 Models stored as `Map<String, dynamic>` instead of a typed class

**Where:** `AiProvider.fetchModels`, `AiProviderModels.models`, `_availableModels`, `AiModelSettings.availableModels`, `_ModelPicker`, `_effectiveModelForUi`, `PiProvider`, `ClaudeCodeProvider._models`.

**Problem:** Model data flows through the entire app as `Map<String, dynamic>`. Every access site uses string-key lookups (`m['provider']`, `m['id']`, `m['reasoning']`, `m['name']`) with no compile-time safety. A typo in any key silently returns `null`. The `_effectiveModelForUi` helper, the keyboard-shortcut cycling logic, and `_ModelPicker` all repeat the same casts.

**Why it matters for simplicity:** A typed `AiModel` class with 4 final fields _removes_ code — every `as String`, `as String?`, null check, and cast disappears, and the IDE catches typos. It's fewer tokens of source for the same features.

**Fix:**

```dart
class AiModel {
  final String id;
  final String name;
  final String provider;
  final bool reasoning;
  const AiModel({required this.id, required this.name, required this.provider, this.reasoning = false});
}
```

Then replace `List<Map<String, dynamic>>` → `List<AiModel>` everywhere. Estimated net line delta: **negative** (fewer lines total).

---

### 1.2 `_snapshotSelection` mutated after popup closes

**Where:** `_submitAiPrompt` (editor_screen.dart, paragraph auto-expand block).

**Problem:** `_snapshotSelection` is a field on `_EditorScreenState`. It's captured in `_openAiPrompt` and then _reassigned_ inside `_submitAiPrompt` (the paragraph expansion). This is fine today because the field is only read later in the same method and in `_acceptDiff`. But if any future code path reads `_snapshotSelection` between `_openAiPrompt` and `_submitAiPrompt`, it sees stale data. The paragraph expansion should produce a local variable, not mutate the snapshot field.

**Fix:** Make the expanded selection a local in `_submitAiPrompt` and pass it through, or expand at snapshot time in `_openAiPrompt` (the highlight code already does this).

---

### 1.3 `_closingTab` guard is never reset on exception

**Where:** `_handleCloseTab` (editor_screen.dart).

**Problem:** `_closingTab` is set `true` before the `try` and reset in `finally`, so this is actually fine structurally. However, the guard only prevents _re-entrant_ calls to `_handleCloseTab` — it doesn't prevent tab-bar mouse clicks from queuing a second close that fires after the dialog returns. In practice this is okay because `showDialog` is modal and captures pointer events, but the comment should say that rather than implying the guard alone is the protection.

---

## 2 — Performance

### 2.1 Debounced session write is synchronous on the UI isolate

**Where:** `SessionService._write` — `writeAsStringSync` + `renameSync`.

**Problem:** Every 500 ms while the user types, `jsonEncode` + sync file I/O runs on the main isolate. For a session with several large documents, this can cause a visible frame skip.

**Fix:** Make the debounced path async (`writeAsString` / `rename`). Keep `flushSync` as-is for the exit path. Net change: ~5 lines.

---

### 2.2 `_spaces` allocates a `List` then joins

**Where:** `EditorArea._spaces`.

```dart
static String _spaces(int count) => List.filled(count, ' ').join();
```

**Fix:** `' ' * count`. Same result, zero allocation, idiomatic Dart.

---

### 2.3 `_computeMatches` rebuilds on every keystroke in the find bar

**Where:** `_onSearchQueryChanged` → `_computeMatches`.

Not a problem at current document sizes, but for large files a `toLowerCase()` of the entire document on every character typed into the search field will lag. If this ever matters, debounce the search query by ~150 ms. No action needed now — just noting.

---

### 2.4 `UnmodifiableListView` is created on every `tabs` access

**Where:** `EditorState.tabs` getter.

```dart
List<EditorTab> get tabs => UnmodifiableListView(_tabs);
```

Each call allocates a new wrapper. It's cheap, but the getter is called many times per frame (tab bar, editor area, search, etc.). Caching the wrapper and invalidating on mutation is trivial:

```dart
UnmodifiableListView<EditorTab>? _tabsView;
List<EditorTab> get tabs => _tabsView ??= UnmodifiableListView(_tabs);
// In every mutation: _tabsView = null;
```

---

## 3 — Idiomatic Dart / Flutter

### 3.1 `onAnyChange` is a nullable `VoidCallback` field — should be a method or a `ChangeNotifier`

**Where:** `EditorState.onAnyChange`.

A public mutable `VoidCallback?` field is the least Dart-idiomatic callback mechanism. It works, but it means only one listener can exist, there's no removal/lifecycle contract, and any code can overwrite it.

**Simpler alternative:** A dedicated `ValueNotifier<int>` bumped on every change (structural or text). `SessionService` listens to it. Zero new classes, clear ownership, multiple listeners possible if needed later.

**Even simpler alternative (if you want to keep the current approach):** Make it a setter with an assertion that it's only set once, and document the contract.

---

### 3.2 `AiModelSettings` data class is a positional grab-bag

**Where:** `AiModelSettings` in `ai_prompt_popup.dart`.

This class has 8 fields and is constructed with all-named parameters. It works, but several fields (`providerKey`, `providerNames`, `supportedThinkingLevels`) are provider-chrome concerns, not model settings. Consider splitting into `AiModelSettings` (models, selection, thinking) and passing provider info separately — or just accept the grab-bag and keep it as-is. Mentioning because the class name doesn't match its scope.

---

### 3.3 `_effectiveModelForUi` is a free function, not a method

**Where:** `ai_prompt_popup.dart`, top-level `_effectiveModelForUi`.

It's called from both `_AiPromptPopupState.build` and `_ModelPicker.build`, plus the keyboard shortcut handler. Making it a static method on `AiModelSettings` would be more discoverable and would move with the class if it's ever extracted.

---

### 3.4 Comments are excellent but occasionally over-explain

**Where:** Throughout, but especially `editor_screen.dart` (175 comment lines out of 1,176 total = 15%).

The comments on _why_ decisions were made (focus management, no `ValueKey`, `IntrinsicHeight` justification) are genuinely valuable. A few comments repeat what the code already says:

```dart
// True while the AI request is in-flight AND while the diff view is shown.
// Keeps the editor readOnly so the snapshot remains valid.
bool _editorReadOnly = false;
```

The name + the single usage site make this self-evident. Trimming the obvious ones would reduce noise without losing the important architectural notes.

---

### 3.5 Prefer `async`/`await` over `.then`/`.catchError` chains

**Where:** `_fetchModelsForActiveProvider` (editor_screen.dart).

```dart
_activeProvider
    .fetchModels()
    .then((result) { ... })
    .catchError((_) { ... });
```

The `then`/`catchError` style is correct but less readable than:

```dart
Future<void> _fetchModelsForActiveProvider() async {
  ...
  try {
    final result = await _activeProvider.fetchModels();
    if (!mounted || _selectedProviderKey != key) return;
    ...
  } catch (_) {
    if (mounted && _selectedProviderKey == key) {
      setState(() => _modelsLoading = false);
    }
  }
}
```

Same behavior, easier to follow, and consistent with every other async method in the file.

---

### 3.6 `import 'dart:ui'` in `main.dart` is unused

**Where:** `lib/main.dart:1`.

`AppExitResponse` is from `dart:ui`, so the import is technically used — but it's re-exported by `package:flutter/foundation.dart` (already transitively available). The `as ui` prefix in `editor_screen.dart` is the correct style; `main.dart` should match or just rely on the transitive export.

---

## 4 — Organization / simplicity

### 4.1 `EditorScreen` is 1,176 lines — the one file that needs splitting

**Where:** `lib/screens/editor_screen.dart`.

This file handles: tab management, file I/O, dialogs, AI prompt lifecycle, streaming, diff accept/reject, model fetching/caching, provider switching, prompt history, find/search, line-move, paragraph detection, and the build tree.

**Suggested split (no new architecture, just file boundaries):**

| Extract to                                       | What moves                                                                                                                                                                        | ~Lines |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `_ai_actions.dart` (mixin or extension on State) | `_openAiPrompt`, `_submitAiPrompt`, `_cancelAiRequest`, `_acceptDiff`, `_rejectDiff`, `_dismissAiPrompt`, model fetch/cache, provider switching, history helpers, snapshot fields | ~350   |
| `_file_actions.dart`                             | `_openFile`, `_saveTab`, `_saveTabAs`, `_writeFile`, `_handleCloseTab`, `_showDirtyCloseDialog`, `_showErrorDialog`, file-name helpers                                            | ~150   |

This leaves `EditorScreen` at ~650 lines (lifecycle, build, search, line-move) — a reasonable size for a screen widget. Both extractions are pure method moves with no new types.

---

### 4.2 Shortcut-blocker map is duplicated in two overlay widgets

**Where:** `ai_prompt_popup.dart` and `ai_diff_view.dart`.

Both define the same `DoNothingAndStopPropagationIntent` map for Ctrl+N/W/O/S/Shift+S/K. If a shortcut is added or changed, both must be updated.

**Fix:** Extract to a shared `const` in `intents.dart`:

```dart
static const overlayBlockedShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyN, control: true): DoNothingAndStopPropagationIntent(),
  // ...
};
```

---

### 4.3 `EditorTab.savedContent` is mutable — easy to get out of sync

**Where:** `editor_tab.dart`.

`savedContent` is a public mutable `String` field. It's written from three places: the constructor, `loadFileIntoTab`, and `onTabSaved`. The dirty check (`controller.text != savedContent`) is duplicated in the controller listener and in `onTabSaved`. A single method `setSavedContent(String)` that also updates `isDirtyNotifier` would eliminate the duplication and make the invariant impossible to break.

---

### 4.4 `_paragraphRangeAt` is a static on `_EditorScreenState` — belongs elsewhere

**Where:** `editor_screen.dart`.

It's a pure text-processing function with no dependency on widget state. Moving it to a `text_utils.dart` file (or making it a top-level function) would make it testable and reusable. Same for `_computeMatches`.

---

## 5 — What's already strong (keep as-is)

- **Flat architecture** — models/state/services/screens/widgets is the right depth for this app. No unnecessary layers.
- **Reactive split** — `ChangeNotifier` for structural changes, `ValueNotifier<bool>` for dirty dots, `TextEditingController` for content. This is textbook Flutter and avoids keystroke rebuilds.
- **Focus management** — deliberate, well-commented, and correct. The `ExcludeFocus` usage on tab buttons is a detail most Flutter apps get wrong.
- **Session restore** — edge cases (missing files, dirty vs clean, counter continuity) are handled thoroughly.
- **AI provider abstraction** — `AiProvider` interface is minimal and sufficient. Adding a third backend would be trivial.
- **`IntrinsicHeight` justification** — the comment in `ai_diff_view.dart` explaining why it's acceptable here is the kind of documentation that saves future developers hours.
- **Minimal dependencies** — only `file_selector`. No state management package, no DI framework, no code generation.

---

## 6 — Suggested action order

| Priority | Item                                                                                              | Effort                     |
| -------- | ------------------------------------------------------------------------------------------------- | -------------------------- |
| 1        | Replace `Map<String, dynamic>` models with typed `AiModel` class (1.1)                            | Small — net negative lines |
| 2        | Make debounced session write async (2.1)                                                          | Tiny — ~5 lines            |
| 3        | Extract `_paragraphRangeAt` / `_computeMatches` to testable utils (4.4)                           | Tiny                       |
| 4        | Extract AI actions and file actions from `EditorScreen` (4.1)                                     | Medium — mechanical move   |
| 5        | Centralize overlay shortcut-blocker map (4.2)                                                     | Tiny                       |
| 6        | `' ' * count` instead of `List.filled` (2.2)                                                      | One-liner                  |
| 7        | `async`/`await` in `_fetchModelsForActiveProvider` (3.5)                                          | Tiny                       |
| 8        | Cache `UnmodifiableListView` (2.4)                                                                | Tiny                       |
| 9        | Optional: typed `onAnyChange` mechanism (3.1), `AiModelSettings` rename (3.2), comment trim (3.4) | Small each                 |

None of these add complexity. Items 1–3 actively reduce it.
