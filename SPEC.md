# Clankpad — Specification

A minimalist Notepad-style text editor with multi-tab support, built in Flutter for desktop (Windows as primary target).

---

## 1. Overview

Clankpad is a simple desktop app: one window, a tab bar, and a text area. No distractions. The basic flow is:

- On launch, one empty tab is ready to type in.
- The user can create more tabs, write in each one, save, open files, and close tabs.
- When the app is closed and reopened, all tabs are restored exactly as they were (including unsaved content).

---

## 2. Features

### 2.1 Tabs

| Action           | Description                                                                                                      |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| `Ctrl+N`         | Creates a new empty tab                                                                                          |
| Click `+`        | Creates a new empty tab (mouse-friendly alternative to `Ctrl+N`)                                                 |
| Click on tab     | Switches to that tab                                                                                             |
| `Ctrl+W`         | Closes the active tab (prompts confirmation if there are unsaved changes)                                        |
| Click `×` on tab | Closes that tab (prompts confirmation if there are unsaved changes)                                              |
| Tab title        | Shows the file name; if no file is assigned, shows `Untitled N` with an ever-incrementing counter (never reused) |
| Dirty indicator  | A dot `●` in the title when there are unsaved changes                                                            |

**Tab bar overflow:** When tabs exceed the available width, the tab bar scrolls horizontally.

**Untitled counter:** The counter increments globally and is never reused. Closing "Untitled 2" and opening a new tab produces "Untitled 3", not "Untitled 2" again.

**Rule:** If the last tab is closed, the app automatically creates a new empty tab (there is always at least one tab).

**Closing a dirty tab — confirmation dialog:**

- _(Phase 1)_ Two options: **Don't Save** and **Cancel**. File I/O is not available yet, so Save is not offered.
- _(Phase 2)_ Three options: **Save**, **Don't Save**, **Cancel**.
    - **Save** — saves the file (opens "Save As" if no path) then closes the tab.
    - **Don't Save** — discards changes and closes the tab.
    - **Cancel** — dismisses the dialog, tab remains open.

### 2.2 Text Area

- Plain text editor (no formatting).
- Monospaced font.
- **Word wrap on by default.** Vertical scroll when content exceeds the screen height.
- The area fills all available space below the tab bar.
- _(Phase 4)_ No-wrap + horizontal scroll mode. Flutter's `TextField` does not support this natively; implementing it may require a dedicated editor package (e.g. `re_editor`). `Alt+Z` will toggle between wrap and no-wrap once implemented.

### 2.3 Open File _(Phase 2)_

| Action   | Method                                                                                             |
| -------- | -------------------------------------------------------------------------------------------------- |
| `Ctrl+O` | Opens the system file picker dialog                                                                |
| Behavior | If the active tab is empty and clean → load the file there. Otherwise → open the file in a new tab |

### 2.4 Save File _(Phase 2)_

| Action         | Method                                                      |
| -------------- | ----------------------------------------------------------- |
| `Ctrl+S`       | Saves the current file. If it has no path → opens "Save As" |
| `Ctrl+Shift+S` | Always opens "Save As" (allows changing name/location)      |

### 2.5 File I/O Edge Cases _(Phase 2)_

**Opening a file already open in another tab:**
Before opening, scan `tabs` for an existing entry with the same file. If found, switch to that tab instead of opening a duplicate. Prevents two tabs silently diverging on the same file.

Path comparison must be **normalized**: use `File(path).absolute.path.toLowerCase()` on both sides before comparing. This handles `C:\x\y` vs `c:/x/y` vs relative paths resolving to the same file on Windows.

**Save failure (permissions, locked file, disk full, etc.):**
Show a modal error dialog with the system error message and an OK button. Do not update `savedContent`, do not clear `isDirty`. The tab stays open and dirty. The user must explicitly acknowledge the failure.

**Restore: session has a `filePath` but the file no longer exists on disk:**

- **Tab was dirty (content stored in session):** Restore the content into the controller, keep `filePath` set (so the user knows where it was), mark the tab dirty. Show a one-time startup notice: _"⚠ [filename] not found at its original path — content restored from last session."_ The user can save it to a new location via Save As.
- **Tab was clean (no content stored in session):** Nothing to restore. Skip the tab silently and show a one-time startup notification: _"[filename] could not be restored — file no longer exists."_ Do not open an empty placeholder tab.

### 2.6 Session Persistence _(Phase 3)_

Clankpad implements a **hot exit**: closing the app never causes data loss.

- On every meaningful change (text edit, tab open/close, active tab switch), a session save is **scheduled**.
- Saves are **debounced at 500ms**: a `dart:async` `Timer` is cancelled and restarted on each change. The write only fires 500ms after the last change, so continuous typing never hammers the disk.
- Saves are **atomic**: the session is written to `session.json.tmp` first, then renamed to `session.json` via `File.rename`. Since rename is atomic on NTFS, a crash mid-write can never corrupt the session file — the previous `session.json` remains intact until the new one is fully written.
- On **app close**, the pending debounce timer (if any) is cancelled and a **synchronous flush** is performed immediately before exit. The Flutter-idiomatic hook for this is `AppLifecycleListener.onExitRequested`: flush the session, then return `AppExitResponse.exit`. Note: force-close (Task Manager, SIGKILL) bypasses this callback — that's acceptable, as the debounced writes already minimize the exposure window.
- On launch, if `session.json` exists, all tabs are restored: their content, file paths, titles, and which tab was active.

**What gets stored per tab:**

| Tab state               | `content` stored?                 | `savedContent` stored?                                   |
| ----------------------- | --------------------------------- | -------------------------------------------------------- |
| File-backed, **clean**  | No — re-read from disk on restore | No — disk content becomes baseline                       |
| File-backed, **dirty**  | Yes — preserves unsaved edits     | Yes — needed to correctly recompute `isDirty` on restore |
| Untitled (no file path) | Yes — always                      | Yes — always                                             |

**Restore logic:**

1. If the `content` key exists in the session entry → set the controller to that text. Use `savedContent` to recompute `isDirty`.
2. If the `content` key is absent → read from `filePath` on disk. That becomes both the controller text and `savedContent` (clean state).
3. If `filePath` no longer exists or is unreadable → fall back to stored `content` if the key exists; otherwise skip the tab (see missing-file edge cases in §2.5).

**Post-restore fixup (after all tabs are processed):**

1. **Min-1-tab rule:** if all tabs were skipped and the list is empty, create one fresh empty tab.
2. **Clamp `activeTabIndex`:** set to `min(storedIndex, tabs.length - 1)`. Must run after step 1 so the list is never empty when clamping.

### 2.7 Inline AI Edit (`Ctrl+K`)

A lightweight inline prompt popup, inspired by Cursor's inline edit feature.

**Trigger:**

- `Ctrl+K` with text selected → opens the popup; the selected text is the **edit target**.
- `Ctrl+K` with no selection → the entire document content is treated as the edit target (equivalent to selecting all).

**Popup behavior:**

- A floating card appears anchored to the **top-center of the editor area** (via `Stack` + `Overlay`), regardless of selection position. This avoids the complexity of computing pixel-level selection coordinates in Flutter.
- The user types a natural-language prompt (e.g. _"make this more formal"_, _"fix the grammar"_).
- `Enter` submits the prompt; the popup closes and the result is applied.
- `Shift+Enter` inserts a newline inside the prompt field.
- `Escape` dismisses the popup with no action.

**Enter/Shift+Enter — explicit key handling required.** On desktop, `TextField` treats `Enter` as a newline like any other key — it does not submit. The popup must intercept via `Focus.onKeyEvent`:

- `Enter` (no modifiers) → call submit; mark event as `KeyEventResult.handled`.
- `Shift+Enter` → return `KeyEventResult.ignored` so the event reaches the `TextField` (inserts newline).
- `Escape` → dismiss popup; mark event as `KeyEventResult.handled`.
- All other keys → return `KeyEventResult.ignored` and pass through normally. This keeps `Ctrl+C/V/X/A/Z` fully functional inside the prompt field.

Do not assume `TextField`'s `onSubmitted` will fire on desktop in a multiline field — it won't.

**Blocking app-level shortcuts while the popup is open.** Wrap the popup widget with a local `Shortcuts` that maps only the specific root-registered app combos to `DoNothingAndStopPropagationIntent`. This prevents them from bubbling up to the root layer without interfering with any other key. `Ctrl+C/V/X/A/Z` are handled internally by Flutter's `EditableText` and never reach the root layer regardless — they need no special treatment.

```dart
Shortcuts(
  shortcuts: {
    SingleActivator(LogicalKeyboardKey.keyN, control: true): DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.keyW, control: true): DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.keyO, control: true): DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.keyS, control: true): DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): DoNothingAndStopPropagationIntent(),
    SingleActivator(LogicalKeyboardKey.keyK, control: true): DoNothingAndStopPropagationIntent(),
  },
  child: /* popup card widget */,
)
```

**Snapshot on popup open.** When the popup opens, immediately capture and freeze:

- `documentText` — full text of the active tab at that moment.
- `editTarget` — the selected substring, or full text if nothing is selected.
- `selectionRange` — the `TextSelection` from the controller.

These values are passed to the AI request unchanged. They do not update if the user types while the popup is open.

**AI context:**

- The AI receives `documentText` as context and `editTarget` as the text to transform.
- The edit instruction is applied only to `editTarget`.

**Editing locked during request.** While the AI request is in-flight, the editor `TextField` is set to `readOnly: true`. A thin linear progress indicator appears below the tab bar. On response (success or error), `readOnly` is restored. Drift detection (applying results against a changed document) is explicitly out of scope — locking is simpler and requests are short.

**Result (Phase 1 — simple replace):**

- The popup closes, then `editTarget` within the document is replaced directly with the AI output using the frozen `selectionRange`. No diff view.

**Result (Phase 3 — diff view):**

- The popup closes, then a diff view appears inline: old text (struck through / red) vs new text (green).
- The user can **Accept** (`Tab` or `Ctrl+Enter`) or **Reject** (`Escape`) the change.

### 2.8 Menu Bar _(optional / Phase 4)_

`File` menu with: New, Open, Save, Save As, Close Tab, Exit.

---

## 3. UI Structure

```
┌─────────────────────────────────────────────────────┐
│  [Untitled 1 ●] [×]  [notes.txt] [×]  [+]    ←scroll│  ← Tab bar (scrollable)
├─────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────┐    │
│  │  [Ctrl+K popup — top-center, Phase 1+]      │    │  ← Overlay (when active)
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  (text area — fills the rest of the window,         │
│   vertical scroll, word wrap on)                    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

- **Tab bar:** horizontally scrollable row of tabs with a `+` button at the end.
- **Text area:** expanded `TextField` (multiline, word wrap on), no borders, comfortable padding, vertical scroll only.
- **AI popup:** rendered via `Overlay`, anchored top-center of the editor area.

---

## 4. Data Model

### EditorTab

```dart
class EditorTab {
  final int id;                                    // unique incrementing integer
  String? filePath;                                // null if the file has not been saved yet
  String title;                                    // file name or "Untitled N"
  String savedContent;                             // content at last save (to detect changes)
  final TextEditingController controller;          // source of truth for current text
  final ValueNotifier<bool> isDirtyNotifier;       // drives only the ● dot in the tab chip

  bool get isDirty => isDirtyNotifier.value;       // convenience getter

  // Called by EditorState when the tab is removed.
  void dispose() {
    controller.dispose();
    isDirtyNotifier.dispose();
  }
}
```

### EditorState

```dart
class EditorState extends ChangeNotifier {
  final List<EditorTab> tabs;
  int activeTabIndex;
  int _nextTabId = 0;        // ever-incrementing ID for each new tab
  int _untitledCounter = 0;  // ever-incrementing counter for "Untitled N" titles
}
```

**Three separate reactive layers — each rebuilds only what it owns:**

| Layer        | Type                             | What listens                                    | Triggered by                            |
| ------------ | -------------------------------- | ----------------------------------------------- | --------------------------------------- |
| Text content | `TextEditingController`          | Editor area (directly, no rebuild needed)       | Every keystroke                         |
| Dirty state  | `ValueNotifier<bool>` per tab    | That tab's chip only (`ValueListenableBuilder`) | Every keystroke                         |
| Structure    | `EditorState` (`ChangeNotifier`) | Tab bar layout, screen scaffold                 | Tab add/close/switch, title/path change |

**Controller listener pattern:** When a tab is created, `EditorState` attaches a listener to its `controller` that updates `isDirtyNotifier` only — it does **not** call `notifyListeners()`. `EditorState.notifyListeners()` is reserved exclusively for structural changes. When a tab is closed, the listener is removed and `tab.dispose()` is called.

```dart
controller.addListener(() {
  tab.isDirtyNotifier.value = controller.text != tab.savedContent;
  // EditorState is not involved — no notifyListeners() here
});
```

### Session File (`session.json`)

```json
{
    "activeTabIndex": 2,
    "nextTabId": 6,
    "untitledCounter": 4,
    "tabs": [
        {
            "id": 3,
            "title": "Untitled 3",
            "filePath": null,
            "content": "some unsaved text...",
            "savedContent": ""
        },
        {
            "id": 4,
            "title": "notes.txt",
            "filePath": "C:/Users/user/Documents/notes.txt"
        },
        {
            "id": 5,
            "title": "draft.txt",
            "filePath": "C:/Users/user/Documents/draft.txt",
            "content": "edited but not yet saved...",
            "savedContent": "original saved text"
        }
    ]
}
```

- Tab `4` (`notes.txt`) is **clean**: `content` and `savedContent` keys are **omitted entirely** — not stored as `null`. Absence of the key is the signal to re-read from disk on restore.
- Tab `5` (`draft.txt`) is **dirty**: both `content` (unsaved edits) and `savedContent` (last save snapshot) are present.
- Tab `3` (`Untitled 3`) has no file path: `content` and `savedContent` are always present.
- `untitledCounter` and `nextTabId` are persisted so numbers never reset across sessions.

---

## 5. Architecture

### State Management

`ChangeNotifier` + `ListenableBuilder`, both built into Flutter. No external package needed.

### Keyboard Shortcuts

Flutter's `Shortcuts` + `Actions` widgets, placed at the **app root level** (wrapping the entire widget tree). Each shortcut maps to a typed `Intent` subclass:

```dart
class NewTabIntent extends Intent {}
class CloseTabIntent extends Intent {}
class SaveIntent extends Intent {}
class SaveAsIntent extends Intent {}
class OpenFileIntent extends Intent {}
class OpenAiPromptIntent extends Intent {}
class AcceptDiffIntent extends Intent {}
class RejectDiffIntent extends Intent {}
```

This approach correctly intercepts shortcuts even when a `TextField` is focused, since the `Shortcuts` layer sits above the focused widget in the dispatch chain.

**Rule: never map keys that overlap with standard text-editing shortcuts.** The root layer only registers app-specific combos (`Ctrl+N`, `Ctrl+S`, `Ctrl+Shift+S`, `Ctrl+O`, `Ctrl+W`, `Ctrl+K`). Flutter's `EditableText` handles `Ctrl+C/V/X/Z/A` internally — as long as those keys are not registered in the root `Shortcuts` map, they pass through untouched.

**Diff overlay — local `Shortcuts` layer inside the overlay widget.** When the diff view is open, `Tab` must accept the diff rather than traverse focus. The solution is a second `Shortcuts` widget scoped _inside_ `ai_diff_view.dart`, not at the root:

```dart
Shortcuts(
  shortcuts: {
    LogicalKeySet(LogicalKeyboardKey.tab):         AcceptDiffIntent(),
    LogicalKeySet(LogicalKeyboardKey.control,
                  LogicalKeyboardKey.enter):        AcceptDiffIntent(),
    LogicalKeySet(LogicalKeyboardKey.escape):       RejectDiffIntent(),
  },
  child: Actions(
    actions: { /* AcceptDiffIntent, RejectDiffIntent handlers */ },
    child: Focus(autofocus: true, child: /* diff UI */),
  ),
)
```

Flutter resolves shortcuts from the **focused widget upward**, so the local layer wins over the root layer while the overlay is focused. When the overlay is dismissed, the bindings disappear automatically — no manual enable/disable flags needed.

---

## 6. Project File Structure

```
lib/
  main.dart                    # Entry point, MaterialApp, Shortcuts/Actions root
  models/
    editor_tab.dart            # EditorTab model
  state/
    editor_state.dart          # EditorState (ChangeNotifier)
  widgets/
    editor_tab_bar.dart        # Horizontally scrollable tab bar
    editor_tab_item.dart       # Individual tab chip; uses ValueListenableBuilder on isDirtyNotifier for ●
    editor_area.dart           # Text area (multiline, word wrap on, vertical scroll)
    ai_prompt_popup.dart       # Floating Ctrl+K prompt input (Overlay)
    ai_diff_view.dart          # Phase 3: inline diff accept/reject overlay
  screens/
    editor_screen.dart         # Main screen: Stack of editor_area + overlays
  services/
    session_service.dart       # Read/write session.json (debounced 500ms, atomic via .tmp rename)
    ai_service.dart            # AI integration placeholder (Pi via MCP — TBD)
```

---

## 7. Development Phases

### Phase 1 — Core (MVP)

**End state:** a working multi-tab editor. Tabs, typing, dirty indicator, keyboard shortcuts all functional. Work is lost on close — that's expected. Every item here is independently testable.

- [x] `EditorTab` model with `dispose()` and `isDirty`
- [x] `EditorState` with controller listener pattern and untitled counter
- [x] UI: scrollable tab bar + text area (vertical scroll, word wrap on)
- [x] Create tab (`Ctrl+N` and `+` button)
- [x] Close tab (`Ctrl+W` and `×` button, with minimum 1 tab rule)
- [x] Unsaved changes indicator (`●`)
- [x] Closing dirty tab: Don't Save / Cancel dialog (Save added in Phase 2)
- [x] `Ctrl+K` popup (top-center overlay, `Enter` submit, `Shift+Enter` newline, `Escape` dismiss)
- [x] AI stub: replaces selected text (or full content) with `[AI: <prompt>]` — confirms the full mechanical flow is wired correctly without real AI

### Phase 2 — File I/O

**End state:** the app is genuinely usable. Open, edit, and save real files. All file-related edge cases handled. A human can do real work and test every file operation.

- [x] Open file (`Ctrl+O`)
- [x] Save (`Ctrl+S`)
- [x] Save As (`Ctrl+Shift+S`)
- [x] Add Save option to dirty-close dialog
- [x] Switch to existing tab if file already open (normalize paths: `File(path).absolute.path.toLowerCase()`)
- [x] Save failure: modal error dialog, tab stays dirty

### Phase 3 — Persistence + AI Diff

**End state:** the app never loses work. Close mid-edit, reopen, everything is back. Ctrl+K now shows a reviewable diff instead of a blind replace.

- [x] Session persistence: debounced write to `session.json` (500ms), atomic via `.tmp` rename, restore on launch, synchronous flush via `AppLifecycleListener.onExitRequested`
- [x] Restore missing-file edge cases (dirty → restore content + notice; clean → skip + notification; clamp `activeTabIndex`; enforce min-1-tab after filtering)
- [x] `Ctrl+K` diff view: old vs new, Accept (`Tab` / `Ctrl+Enter`) or Reject (`Escape`)

### Phase 4 — Polish

**End state:** the app feels complete and native. Visual refinements and quality-of-life improvements.

- [ ] Window title reflects the active file
- [ ] No-wrap + horizontal scroll mode with `Alt+Z` toggle (evaluate dedicated editor package e.g. `re_editor`)
- [ ] Native app menu (File menu on Windows/macOS)
- [ ] Font size adjustment
- [ ] Light / dark theme
- [ ] True inline `Ctrl+K` popup positioning near the selection (via `RenderEditable`)

---

## 8. Dependencies

Only one external package is used. Everything else relies on the Flutter/Dart standard library.

| Package         | Purpose                       | Why not stdlib?                                                           |
| --------------- | ----------------------------- | ------------------------------------------------------------------------- |
| `file_selector` | Native open/save file dialogs | Requires OS-level calls (Windows COM API); no built-in Flutter equivalent |

**Stdlib replacements:**

| Need                   | Solution                                                    |
| ---------------------- | ----------------------------------------------------------- |
| State management       | `ChangeNotifier` + `ListenableBuilder` (built into Flutter) |
| Tab IDs                | Incrementing integer counter (`_nextTabId`)                 |
| App data directory     | `dart:io` + `Platform.environment['APPDATA']` (Windows)     |
| Text diffing (Phase 3) | Simple line-by-line diff with `dart:core`                   |
| JSON serialization     | `dart:convert`                                              |
| File read/write        | `dart:io`                                                   |
