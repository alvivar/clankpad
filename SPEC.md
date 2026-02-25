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

- `Ctrl+K` with text selected → opens the popup in **edit mode**; the selected text is the **edit target**; the AI output replaces it.
- `Ctrl+K` with no selection on a **non-blank line** → the surrounding paragraph is auto-selected → edit mode (same as a manual selection of that paragraph).
- `Ctrl+K` with no selection on a **blank line** → opens the popup in **insert mode**; the AI output is **inserted at the cursor position**.

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
- `editTarget` — the selected substring, or empty string in insert mode.
- `selectionRange` — the `TextSelection` from the controller.

These values are passed to the AI request unchanged. They do not update if the user types while the popup is open.

**AI context:**

- **Edit mode** (selection exists): the AI receives `documentText` as context and `editTarget` as the text to transform. The output replaces `editTarget`.
- **Insert mode** (no selection, blank line): the AI receives the full document with a `[CURSOR]` marker embedded at the insertion point. The model sees the document as a coherent whole and is instructed to reply with only the text to insert — without surrounding blank lines. On accept, the editor wraps the (trimmed) result with `\n…\n`, producing a blank-line separation from both the preceding and following paragraphs.

**Editing locked during request.** While the AI request is in-flight, the editor `TextField` is set to `readOnly: true`. A thin linear progress indicator appears below the tab bar. On response (success or error), `readOnly` is restored. Drift detection (applying results against a changed document) is explicitly out of scope — locking is simpler and requests are short.

**Result (Phase 1 — simple replace):**

- The popup closes, then `editTarget` within the document is replaced directly with the AI output using the frozen `selectionRange`. No diff view.

**Result (Phase 3 — diff view):**

- The popup closes, then a diff view appears inline: old text (struck through / red) vs new text (green).
- The user can **Accept** (`Tab` or `Ctrl+Enter`) or **Reject** (`Escape`) the change.

**Streaming _(Phase 3.7)_:**

- `AiService` is replaced by `PiRpcService`, which spawns `pi --mode rpc` as a child process and communicates via line-delimited JSON over stdin/stdout (Pi's RPC protocol).
- `PiRpcService.streamEdit(...)` returns a `Stream<String>` of text chunks — each chunk comes from a `message_update` event with `assistantMessageEvent.type == "text_delta"`.
- The diff view's "After" pane updates live as chunks arrive — the user sees the response being written in real time.
- `EditorScreen` accumulates chunks into `_diffProposed` and calls `setState` on each, keeping the diff card reactive with no additional state class.
- A **Cancel** button (below the tab bar, replacing the progress indicator) aborts the in-flight Pi run at any point by sending `{"type": "abort"}` to Pi's stdin. `Escape` while no popup or diff is visible has the same effect.
- Errors (Pi not found, Pi process crashed, model error reported by Pi) surface as a dismissable **error banner** below the tab bar rather than a blocking dialog. The editor unlocks immediately so the user is never stuck waiting for a button click to resume.

### 2.8 Menu Bar _(optional / Phase 4)_

`File` menu with: New, Open, Save, Save As, Close Tab, Exit.

### 2.9 Pi as AI Backend _(Phase 3.7)_

Clankpad delegates all AI calls to **Pi** (`pi --mode rpc`), an external agent process it spawns as a child process. Clankpad never calls any model API directly — Pi owns auth, model selection, retry logic, and streaming.

**Why Pi?**

- Pi already handles auth for every supported provider (Anthropic, OpenAI, Google, etc.) via its own `~/.pi/agent/settings.json` and `/login` OAuth flow. Clankpad inherits all of this for free.
- Pi's RPC mode exposes a clean line-delimited JSON protocol over stdin/stdout — a natural fit for `dart:io`'s `Process.start`.
- Swapping the underlying model (e.g. `claude-sonnet-4` → `gpt-4o`) requires no Clankpad code changes — only the Pi spawn arguments change.

**Prerequisites:**

Pi must be installed and configured on the user's machine (`npm install -g @mariozechner/pi-coding-agent`, then `pi /login` or API key set). Clankpad does not manage Pi's configuration. If `pi` is not on `PATH`, a settings field will allow specifying an absolute path.

**No API key in Clankpad.** Auth lives entirely in Pi's config. Clankpad has no `config.json`, no key dialog, no key rotation UI.

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
  final ScrollController scrollController;         // per-tab scroll position (see §5 Focus Management)
  final ValueNotifier<bool> isDirtyNotifier;       // drives only the ● dot in the tab chip

  bool get isDirty => isDirtyNotifier.value;       // convenience getter

  // Called by EditorState when the tab is removed.
  void dispose() {
    controller.dispose();
    scrollController.dispose();
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

Flutter's `Shortcuts` + `Actions` widgets, placed at the **`EditorScreen` level** (wrapping the `Scaffold` and everything below it). Each shortcut maps to a typed `Intent` subclass:

> **Why not at the `MaterialApp` root?** `Shortcuts` and `Actions` must stay together in the widget tree. Flutter's dispatch walks _upward_ from the focused widget to find `Shortcuts` (maps key → intent), then continues upward to find `Actions` (maps intent → handler). If they were split across a `Navigator` boundary — `Shortcuts` above `MaterialApp`, `Actions` inside `EditorScreen` — a second route's focused widget would find the `Shortcuts` but walk up through a parallel subtree that does not contain `EditorScreen`'s `Actions`, so all shortcuts would silently do nothing. Additionally, all registered shortcuts are editor-specific (`Ctrl+N` creates a tab, etc.); activating them while a hypothetical settings route is active would be semantically wrong. `EditorScreen` scope is correct by design.

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
    SingleActivator(LogicalKeyboardKey.tab):                       AcceptDiffIntent(),
    SingleActivator(LogicalKeyboardKey.enter, control: true):      AcceptDiffIntent(),
    SingleActivator(LogicalKeyboardKey.escape):                    RejectDiffIntent(),
  },
  child: Actions(
    actions: { /* AcceptDiffIntent, RejectDiffIntent handlers */ },
    child: Focus(focusNode: focusNode, child: /* diff UI */),
  ),
)
```

Flutter resolves shortcuts from the **focused widget upward**, so the local layer wins over the root layer while the overlay is focused. When the overlay is dismissed, the bindings disappear automatically — no manual enable/disable flags needed.

**Important:** do not use `autofocus: true` on the diff overlay's `Focus` widget. Flutter's `autofocus` only acquires focus when _no other node in the same scope is currently focused_. Because the editor's `_editorFocusNode` is always focused when the diff appears, `autofocus` silently does nothing. Focus must be driven explicitly (see §5 Focus Management).

### Focus Management

Focus in a multi-tab desktop app has several subtle failure modes. This section documents the decisions that make focus work correctly in all cases.

**Rule: the editor `TextField` must always hold focus unless a popup or diff overlay is explicitly active.**

This is what makes keyboard shortcuts work immediately after any tab operation, without requiring the user to click the editor first.

#### No `ValueKey` on the editor `TextField`

The editor `TextField` has no `key:` prop. Flutter therefore reuses the same element across tab switches — only `controller` and `scrollController` change. Since the element never leaves the tree, `_editorFocusNode` is never detached and focus is never lost during tab switches triggered by keyboard shortcuts (`Ctrl+N`, `Ctrl+W`).

Early versions used `key: ValueKey(tab.id)`, which destroyed and recreated the `TextField` on every tab switch. This caused two problems: (a) a detach/reattach cycle on `_editorFocusNode` that raced with the keyboard event system, breaking shortcut focus on the keyboard path; (b) `autofocus: true` only fired on the mouse path (where focus was lost then re-requested), never on the keyboard path (where no focus change occurred).

#### Per-tab `ScrollController`

Because `ValueKey` was removed, Flutter no longer resets the `TextField`'s internal scroll position on tab switch. Each `EditorTab` owns a `ScrollController` that is passed to the `TextField`. Switching tabs swaps the controller, preserving each tab's scroll position independently — the same behaviour as before, without the element recreation.

#### Persistent `FocusNode`s in `EditorScreen`

`EditorScreen` owns two long-lived `FocusNode`s:

| Field              | Passed to                  | Purpose                                                                           |
| ------------------ | -------------------------- | --------------------------------------------------------------------------------- |
| `_editorFocusNode` | `EditorArea` → `TextField` | Allows explicit focus restoration to the editor after any event that clears focus |
| `_diffFocusNode`   | `AiDiffView` → `Focus`     | Allows explicit focus grant to the diff overlay once it is mounted                |

Both are created in the field initialiser and disposed in `State.dispose()`.

#### `ExcludeFocus` on tab bar buttons

All `IconButton`s in the tab bar (the `×` close button on each tab and the `+` new-tab button) are wrapped in `ExcludeFocus(excluding: true)`. This prevents the button from acquiring focus when clicked. Without it, clicking any tab bar button would call `requestFocus()` on the button's internal `FocusNode`, moving focus away from the editor.

#### Restoring focus after mouse clicks

On desktop, clicking a non-focusable widget (a `GestureDetector` tab chip, or an `ExcludeFocus`-wrapped button) clears the current focus — Flutter's `FocusManager` removes the current owner without assigning a new one. The editor loses focus even though no new widget claimed it.

`EditorScreen._onEditorStateChanged` (called on every structural `EditorState` change) schedules a post-frame `_editorFocusNode.requestFocus()`:

```dart
void _onEditorStateChanged() {
  setState(() {});
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_aiPromptVisible && !_diffVisible) {
      _editorFocusNode.requestFocus();
    }
  });
}
```

The post-frame wait ensures the rebuild (which may have mounted a new widget subtree) is fully committed before touching the focus tree. The guard prevents the callback from stealing focus back from an active popup or diff overlay.

On the keyboard-shortcut path, `_editorFocusNode` already holds focus; calling `requestFocus()` on an already-focused node is a no-op in Flutter's `FocusManager` — so there is no double-focus or interference.

#### Restoring focus after popup and diff dismissal

When the AI prompt popup or diff overlay is dismissed, its `Focus` widget is removed from the tree. Flutter does not automatically return focus to the previous owner — it goes nowhere. Both `_dismissAiPrompt` and `_acceptDiff`/`_rejectDiff` explicitly call `_editorFocusNode.requestFocus()` after their `setState`.

#### Granting focus to the diff overlay

`autofocus: true` cannot be used (see above). Instead, `_submitAiPrompt` schedules a post-frame `_diffFocusNode.requestFocus()` after the `setState` that makes the diff visible:

```dart
setState(() { _diffVisible = true; ... });
WidgetsBinding.instance.addPostFrameCallback((_) {
  if (mounted) _diffFocusNode.requestFocus();
});
```

The post-frame wait is required because `_diffFocusNode` is not attached to any element until `AiDiffView` mounts in the next build.

#### Cursor visibility after keyboard-shortcut tab switches

`TextEditingController(text: content)` initialises its selection to `TextSelection.collapsed(offset: -1)`. Offset `-1` is a sentinel meaning "no cursor placed yet". `EditableText` corrects this automatically in `_handleFocusChanged(true)` — but that event only fires when focus is _gained_, not when it was already held.

On the keyboard-shortcut path, focus never leaves the editor, so `_handleFocusChanged` never fires for the new controller, and the cursor is not rendered.

All `EditorTab` controllers are therefore initialised with an explicit valid selection:

```dart
controller = TextEditingController.fromValue(
  TextEditingValue(
    text: initialContent,
    selection: const TextSelection.collapsed(offset: 0),
  ),
);
```

Offset `0` is always valid (start of text) and causes `EditableText` to render the cursor immediately, regardless of whether a focus-change event has fired.

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
    pi_rpc_service.dart        # Phase 3.7: Pi subprocess RPC client — stdin/stdout JSON, text_delta streaming
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

### Phase 3.5 — Focus & Input Correctness

**End state:** keyboard shortcuts and the text cursor work correctly in every scenario — after tab switches, after using the mouse, and after accepting or rejecting an AI diff. No clicking required to "re-activate" the editor.

Root causes discovered and resolved (all documented in §5 Focus Management):

- [x] Remove `ValueKey` from the editor `TextField` — prevents the detach/reattach race that broke shortcut focus on the keyboard path
- [x] Add per-tab `ScrollController` on `EditorTab` — preserves scroll position per tab without `ValueKey`
- [x] `ExcludeFocus` on all tab bar `IconButton`s — prevents click-based focus theft
- [x] Post-frame `_editorFocusNode.requestFocus()` in `_onEditorStateChanged` — restores focus after mouse clicks clear it (mouse clicks on non-focusable widgets silently clear focus on desktop)
- [x] Explicit `_editorFocusNode.requestFocus()` after popup and diff dismissal — Flutter does not automatically return focus when a `Focus` widget leaves the tree
- [x] Replace `autofocus: true` on the diff overlay with `_diffFocusNode` driven by a post-frame `requestFocus()` — `autofocus` only fires when no sibling is focused; the editor is always focused when the diff appears, so `autofocus` was a silent no-op
- [x] Initialise all `TextEditingController`s with `TextSelection.collapsed(offset: 0)` — the default offset `-1` sentinel is not rendered as a cursor unless a focus-change event fires, which never happens on the keyboard-shortcut path

### Phase 3.6 — Code Review Polish

**End state:** all code-review findings triaged. Changes that improve correctness or clarity are applied; proposals that would regress behaviour or add complexity without benefit are explicitly declined and documented.

#### Applied fixes

- [x] `EditorArea.focusNode` made non-nullable and `required` — the field is load-bearing; the nullable type was misleading and forced a pointless `?` propagation into `TextField`
- [x] `AiService` moved from inline instantiation (`AiService()` per call) to a persistent `_aiService` field on `_EditorScreenState`; `dispose()` stub added so the teardown hook is wired before real AI integration lands
- [x] Controller listener `onAnyChange` guard — the listener now calls `onAnyChange` only when `newDirty || changed` (content is dirty, or the dirty flag just flipped). Previously it called unconditionally, causing a redundant second call in `loadFileIntoTab`'s reuse branch where `_structuralChange()` already covered the notification
- [x] `EditorState.startupNotices` made private (`_startupNotices`); public surface replaced with `bool get hasStartupNotices` and `List<String> takeStartupNotices()` (atomic read-and-clear). `restoreFromSession` changed from `Future<List<String>>` to `Future<void>`, populating `_startupNotices` internally — the two-step assign in `main.dart` is gone
- [x] `AiDiffView` shortcuts map — `const` moved to the map literal (`const { … }`) rather than individual entries; the `const` context propagates inward so per-entry annotations were redundant noise
- [x] `_saveTab` flattened to guard clauses — the `else` branch after a returning `if` was removed; three exit paths now read as a flat sequence
- [x] `SessionService` constructor — `sep` local variable removed; `Platform.pathSeparator` inlined to match `readSession()`'s style
- [x] `EditorState.tabs` getter changed from `List.unmodifiable(_tabs)` (O(n) element copy on every access) to `UnmodifiableListView(_tabs)` (O(1) wrapper, no copy, reflects live list, still throws on mutation)

#### Declined — design kept, rationale documented in code

- **`dart:ui` import removal** — `AppExitResponse` is defined in `dart:ui` and is _not_ re-exported by `package:flutter/material.dart`; removing the import causes a compile error. Import retained.
- **`onAnyChange` → `ChangeNotifier.addListener`** — `addListener` only fires when `notifyListeners()` is called, which is restricted to structural changes. Text edits deliberately skip `notifyListeners()` to avoid full UI rebuilds on keystrokes. Migrating session saves to `addListener` would silently drop all keystroke-level persistence. `onAnyChange` is the correct two-channel design; a detailed comment in `EditorState` explains the split.
- **`_dismissAiPrompt` / `_acceptDiff` / `_rejectDiff` focus inconsistency** — synchronous `requestFocus()` is correct here because `_editorFocusNode` is permanently attached (no `ValueKey`, no element recreation). The post-frame callback in `_onEditorStateChanged` is needed for a different reason: mouse clicks clear focus before the structural change fires. Comments added to each method to prevent future "cleanup" that would introduce a spurious post-frame wait.
- **`EditorState` constructor creates a tab that is immediately discarded** — a factory constructor cannot be async, so it cannot skip the initial tab when `restoreFromSession` is to be called; any `EditorState.empty()` / `ensureInitialTab()` approach leaks internal invariants into the public API. Cost is three short-lived object allocations at startup. Comment added to the constructor.
- **`Shortcuts` + `Actions` at app root** — `Shortcuts` and `Actions` must be co-located in the widget tree. Flutter's dispatch walks upward from the focused widget: `Shortcuts` captures the intent, then continues upward to find `Actions`. If split across a `Navigator` boundary, a second route's upward path does not include `EditorScreen`'s `Actions` subtree — all shortcuts would silently fail. Additionally, every registered shortcut is editor-specific; activating them from a hypothetical settings route would be semantically wrong. `EditorScreen` scope is correct by design. Comment added; SPEC §5 updated.
- **`IntrinsicHeight` in `AiDiffView`** — no `IntrinsicHeight`-free layout simultaneously satisfies all three constraints: card shrinks to content, panes are equal height, each pane scrolls independently when content exceeds the cap. `ConstrainedBox` with a fixed max-height on each pane fails the shrink-wrap requirement (card is always full height for short diffs). Flutter's quadratic-intrinsic-measurement warning targets hot paths (e.g., inside scrolling lists); here it wraps a static ~20-node tree evaluated once per AI response. Comment added explaining the trade-off and pre-empting the `ConstrainedBox` refactor.

### Phase 3.7 — Pi RPC Integration

**End state:** `Ctrl+K` drives a real AI model through Pi's RPC subprocess. Responses stream token-by-token into the live diff view. The user can cancel mid-stream. Pi process errors surface as a non-blocking banner. No API key management lives in Clankpad — Pi owns auth entirely.

#### Protocol recap (from Pi RPC spec)

Pi runs as a child process (see spawn args below). Commands are JSON lines sent to its stdin; events and responses come back as JSON lines on stdout. Stderr must be continuously drained or the child process can block.

The only events Clankpad acts on:

| Event                                      | When                  | What we do                                                          |
| ------------------------------------------ | --------------------- | ------------------------------------------------------------------- |
| `message_update` (delta type `text_delta`) | Token arrives         | Append `assistantMessageEvent.delta` to `_diffProposed`; `setState` |
| `agent_end`                                | Pi finished           | Finalize diff, hide progress indicator                              |
| `auto_retry_end` (`success: false`)        | All retries exhausted | Show error banner, unlock editor                                    |

Everything else (thinking deltas, tool events, compaction events, etc.) is silently ignored.

#### `PiRpcService` — replaces `AiService`

```dart
class PiRpcService {
  PiRpcService({this.piExecutable = 'pi'});

  final String piExecutable; // overridable for non-PATH installs

  Process? _process;             // null → no warm process alive
  StreamSubscription? _stdoutSub; // persistent; created at spawn, cancelled in dispose
  StreamController<String>? _lineController; // per-invocation; created on streamEdit entry, closed in finally

  /// Spawns Pi on first call (or after a crash), reuses the warm process
  /// on subsequent calls. Yields text chunks as they arrive.
  /// Completes normally when agent_end arrives (including after abort).
  /// Throws PiRpcError on process launch failure or final retry failure.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
  });

  /// Sends {"type": "abort"} to Pi's stdin.
  /// Safe to call when no stream is active — no-op.
  void abort();

  /// Cancels the stdout subscription, closes the line controller, kills Pi.
  Future<void> dispose();
}
```

**Pi spawn args:**

```
pi --mode rpc --no-session --no-tools
   --no-extensions --no-skills --no-prompt-templates
```

`--no-session` — stateless, no session file written.
`--no-tools` — model can only return text; no file system access.
`--no-extensions --no-skills --no-prompt-templates` — minimal, deterministic subprocess; nothing from the user's `~/.pi/agent/` loads.

On Windows, `pi` is a `.cmd` wrapper. `Process.start` must use `runInShell: true` so the OS resolves `pi.cmd` correctly.

**Prompt message format:**

```
Document context:
<full document text>

Edit target:
<selected text, or full document if no selection>

Instruction: <user's typed instruction>

IMPORTANT: Reply with ONLY the transformed text. No explanations, no preamble.
```

Each invocation sends two commands back-to-back (no waiting between them):

```
{"type": "new_session"}
{"type": "prompt", "message": "..."}
```

`new_session` clears Pi's in-memory conversation history before each edit, so invocations are independent. It is a no-op on a fresh process and a reset on a warm one. Because the event loop already ignores non-`prompt` response types with `continue`, the `new_session` acknowledgement passes through without any special handling.

**Handling the `prompt` command response:**

Pi responds with `{"type": "response", "command": "prompt", "success": true/false}` before events start streaming. If `success: false`, throw `PiRpcError`. If `success: true`, events follow — no action needed.

**Text delta extraction:**

```dart
if (event['type'] == 'message_update') {
  final delta = event['assistantMessageEvent'];
  if (delta?['type'] == 'text_delta') {
    yield delta['delta'] as String;
  }
}
```

**Abort:**

Sends `{"type": "abort"}` to Pi's stdin. Pi stops mid-stream and emits `agent_end`. The stream completes normally — no error banner shown. The process stays warm.

**Process lifecycle:**

Pi is spawned on the first `Ctrl+K` and kept alive between invocations. `proc.stdout` is single-subscription, so a persistent `StreamSubscription` (`_stdoutSub`) is created at spawn time and forwards every stdout line to a per-invocation `StreamController<String>` (`_lineController`). `streamEdit` reads from `_lineController.stream`; when `agent_end` arrives, `_lineController` is closed and nulled while `_stdoutSub` stays alive for the next call.

The process is killed only on error paths (`!agentEndReceived`). On success and after abort, the process stays warm. If Pi exits unexpectedly between invocations, `_stdoutSub.onDone` fires: `_process` and `_stdoutSub` are nulled, and `_lineController` is closed if open (which signals an error to any active stream). The next `streamEdit` call sees `_process == null` and spawns fresh.

`_killProcess()` calls `proc.kill()` **synchronously as its first action**, before any `await` points. This guarantees Pi is signalled even if the Dart process exits during the subsequent async cleanup (`_stdoutSub.cancel()`, `proc.stdin.close()`). Without this ordering, a force-close of Clankpad could exit the Dart process between awaits, leaving Pi orphaned on Windows (child processes are not automatically killed when the parent exits on Windows — no Job Object is in use).

`dispose()` closes `_lineController` first (unblocking any active stream), then delegates to `_killProcess()`.

**Stderr drain:**

A dedicated listener on `proc.stderr` discards lines. Without it, the child's stderr pipe fills and the process blocks.

#### Error handling — error banner

Two failure conditions surface as a dismissable **error banner** below the tab bar. The editor unlocks immediately.

| Condition                                                               | Banner text                                                                                                |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `pi` not found (process launch fails)                                   | "`pi` not found — install it with `npm install -g @mariozechner/pi-coding-agent` and ensure it's on PATH." |
| Pi exits without `agent_end`, or `auto_retry_end` with `success: false` | "Pi process exited unexpectedly — try again."                                                              |

The banner persists until the user clicks `×`. A new error replaces the previous one.

#### `EditorScreen` changes

| Concern              | Change                                                                                                                                                                                                                                                                                         |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Service field        | `_aiService` (type `AiService`) → `_piRpcService` (type `PiRpcService`).                                                                                                                                                                                                                       |
| `_submitAiPrompt`    | `await for`s chunks from `streamEdit`; first chunk triggers `_diffVisible = true` + `_diffFocusNode.requestFocus()` (post-frame); subsequent chunks append to `_diffProposed` + `setState`. Wrapped in `try/catch/finally`: catch sets `_errorBanner`, finally sets `_editorReadOnly = false`. |
| Cancel button        | Shown while `_editorReadOnly && !_diffVisible`. Calls `_piRpcService.abort()` + unlocks editor. Once the diff is visible this button is gone — the cancel path from that point is Reject (Escape or button), which also calls `abort()`.                                                       |
| Escape-while-loading | `Focus.onKeyEvent` on `EditorScreen`: `Escape` when `_editorReadOnly && !_aiPromptVisible && !_diffVisible` → calls `abort()`.                                                                                                                                                                 |
| `_rejectDiff`        | Calls `_piRpcService.abort()` before the existing `setState`. Stops Pi if the stream is still running when the user rejects; no-op if it has already finished.                                                                                                                                 |
| Error banner         | New `String? _errorBanner` field. Set on error; cleared on dismiss or next `Ctrl+K`. Rendered as a thin coloured row below the tab bar with a `×` dismiss button.                                                                                                                              |
| Dispose              | `_piRpcService.dispose()` in `State.dispose()`.                                                                                                                                                                                                                                                |

#### Phase 3.7 task checklist

- [x] Rename `ai_service.dart` → `pi_rpc_service.dart`; replace `AiService` stub with `PiRpcService`
- [x] `PiRpcService(piExecutable)` constructor with `_process`, `_stdoutSub`, `_lineController` fields
- [x] On `streamEdit`: if `_process == null`, spawn Pi (`runInShell: true`), drain stderr, set up persistent `_stdoutSub` that forwards lines to `_lineController` and nulls itself + process on `onDone`
- [x] Send `new_session` + `prompt` back-to-back; flush once; create `_lineController` per invocation
- [x] Event loop reads from `_lineController.stream`; `finally` closes + nulls `_lineController`; kills process only if `!agentEndReceived`
- [x] `prompt` response check — if `success: false`, throw `PiRpcError`
- [x] `auto_retry_end (success: false)` → throw `PiRpcError`
- [x] Process exit without `agent_end` (stdout closes) → `_stdoutSub.onDone` closes `_lineController`; active stream errors; next call spawns fresh
- [x] `PiRpcService.abort()` — write `{"type":"abort"}` to stdin; no-op if no process
- [x] `PiRpcService.dispose()` — close `_lineController` (unblocks active stream), then `_killProcess()` which kills `_process` first (synchronous), then cancels `_stdoutSub`
- [x] `EditorScreen`: replace `_aiService` with `_piRpcService: PiRpcService`
- [x] `_submitAiPrompt`: `await for` stream; open diff on first chunk; `try/catch/finally` to set error banner and unlock editor
- [x] Cancel button — shown while `_editorReadOnly && !_diffVisible`; calls `abort()` + unlocks editor
- [x] `_rejectDiff` calls `_piRpcService.abort()` before `setState` — stops Pi if stream still running
- [x] Escape-while-loading guard via `Focus.onKeyEvent` on `EditorScreen` → calls `abort()`
- [x] Error banner — inline in `EditorScreen.build`; `String? _errorBanner` field; `×` dismiss button
- [x] No new packages — `dart:io Process.start` + `dart:convert` handle everything

---

### Phase 3.8 — Prompt History

**End state:** pressing Up/Down in the `Ctrl+K` prompt field navigates through previously submitted instructions, identical to Cursor's AI edit UX.

#### Behaviour

- History is session-only (in memory, not persisted to disk).
- Entries are appended on every successful submit. Consecutive duplicates are skipped. Capped at 50 entries.
- Up/Down only trigger history navigation when the cursor is on the **first / last line** of the field respectively. When the cursor is mid-text, Up/Down move the caret normally.
- The first Up press saves whatever is currently in the field (`_historySavedInput`). Pressing Down past the newest history entry restores it — nothing the user typed is lost.
- History index resets to `_promptHistory.length` (past-the-end) every time the popup opens.
- Both `KeyDownEvent` and `KeyRepeatEvent` trigger history navigation so holding the key scrolls smoothly.

**Navigation example:**

```
field:  "make it bold"          ← user typed this, hasn't submitted yet
Up  →   "previous instruction"  ← _historySavedInput = "make it bold"
Up  →   "older instruction"
Down →  "previous instruction"
Down →  "make it bold"          ← restored from _historySavedInput
```

After navigation the cursor is placed at the end of the restored text.

#### Cursor-position helpers (on `_AiPromptPopupState`)

```dart
bool _isOnFirstLine() {
  final offset = _promptController.selection.baseOffset;
  if (offset < 0) return false;
  return !_promptController.text.substring(0, offset).contains('\n');
}

bool _isOnLastLine() {
  final offset = _promptController.selection.baseOffset;
  if (offset < 0) return false;
  return !_promptController.text.substring(offset).contains('\n');
}
```

#### History methods (on `_EditorScreenState`)

```dart
String? _historyUp(String currentText) {
  if (_promptHistory.isEmpty) return null;
  if (_historyIndex == _promptHistory.length) {
    _historySavedInput = currentText; // first Up — save current draft
  }
  if (_historyIndex > 0) {
    _historyIndex--;
    return _promptHistory[_historyIndex];
  }
  return null; // already at oldest — TextField handles Up normally
}

String? _historyDown(String currentText) {
  if (_historyIndex >= _promptHistory.length) return null;
  _historyIndex++;
  return _historyIndex == _promptHistory.length
      ? _historySavedInput  // past end — restore saved draft
      : _promptHistory[_historyIndex];
}
```

`null` means "no history move — let the TextField handle the key normally."

#### `Focus.onKeyEvent` restructure in `AiPromptPopup`

Up/Down are handled on `KeyDownEvent` and `KeyRepeatEvent`; Enter/Escape remain `KeyDownEvent`-only:

```
if (KeyDown or KeyRepeat) AND arrowUp AND _isOnFirstLine():
    result = onHistoryUp(currentText)
    if result != null → set controller text, cursor to end, return handled
    else → return ignored   ← TextField moves cursor up normally

same pattern for arrowDown + _isOnLastLine()

if not KeyDownEvent → return ignored   ← existing gate for Enter/Escape
handle Enter, Escape as today
```

#### Changes

| File                   | What changes                                                                                                                                                                                                                                                               |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `editor_screen.dart`   | Add `_promptHistory`, `_historyIndex`, `_historySavedInput` fields; add `_historyUp` / `_historyDown` methods; update `_submitAiPrompt` (append to history, reset index); reset index + saved input on popup open; pass `onHistoryUp` / `onHistoryDown` to `AiPromptPopup` |
| `ai_prompt_popup.dart` | Add `onHistoryUp` / `onHistoryDown` callback parameters; add `_isOnFirstLine` / `_isOnLastLine` helpers; restructure `Focus.onKeyEvent`                                                                                                                                    |

#### Phase 3.8 task checklist

- [x] `EditorScreen`: add `List<String> _promptHistory`, `int _historyIndex`, `String _historySavedInput` fields
- [x] `EditorScreen`: add `_historyUp(String) → String?` and `_historyDown(String) → String?` methods
- [x] `EditorScreen`: on popup open — reset `_historyIndex = _promptHistory.length`, `_historySavedInput = ''`
- [x] `EditorScreen`: in `_submitAiPrompt` — append to `_promptHistory` (skip consecutive duplicate, cap 50), reset `_historyIndex`
- [x] `EditorScreen`: pass `onHistoryUp` and `onHistoryDown` to `AiPromptPopup`
- [x] `AiPromptPopup`: add `onHistoryUp` / `onHistoryDown` nullable callback parameters
- [x] `AiPromptPopup`: add `_isOnFirstLine` / `_isOnLastLine` helpers
- [x] `AiPromptPopup`: restructure `Focus.onKeyEvent` — Up/Down on `KeyDownEvent`+`KeyRepeatEvent`; Enter/Escape `KeyDownEvent`-only

---

### Phase 3.9 — Model & Thinking Level Picker

**End state:** the `Ctrl+K` popup shows a footer toolbar with a model dropdown and a thinking level selector. Pi's auth and model configuration remain the single source of truth — Clankpad only reads what Pi already knows.

#### UX

A thin footer row sits below the text field, separated by a `Divider`:

- **Model** (left): `DropdownButton` listing models from `get_available_models`, filtered by `enabledModels` from `~/.pi/agent/settings.json`. Each item shows `provider  ·  Model Name`. Shows `···` while loading, disappears on error. Seeded from Pi's current model via `get_state`.
- **Thinking level** (right): `DropdownButton` — `Thinking off · Low thinking · Medium thinking · High thinking`. **Only shown when the selected model has `reasoning: true`.** Seeded from Pi's live thinking level via `get_state`, normalised via `_normaliseLevel()`. `set_thinking_level` is always sent on submit — Pi ignores it for non-reasoning models.

Both selections are session-only (in memory).

**Loading state** (first popup open): model dropdown shows `···` and is disabled; thinking dropdown is hidden until an effective model can be resolved. Pi spawns in background; `setState` updates once all three parallel calls return.

**Error state** (any fetch fails): model dropdown disappears; thinking dropdown stays. Submit still works.

#### Pi RPC flow

**On popup open** — non-blocking, runs while user types:

1. `PiRpcService.warmUp()` → `_ensureRunning()` spawns Pi if not already alive
2. Parallel fetch: `get_available_models` + `get_state` + `loadEnabledModelPatterns`
3. Filter models by `enabledModels`; seed thinking level from `get_state`; if Pi's current model exists in filtered list seed provider/model selection

**On submit** — prepended to existing write sequence, one `flush()`:

1. `set_model` (if `_selectedModelId != null`)
2. `set_thinking_level` (always; Pi ignores it for non-reasoning models)
3. `new_session` + `prompt` as today

`set_model` and `set_thinking_level` are sent **without** an `id` and handled by the existing event loop — same pattern as `new_session` and `prompt` today. No `Completer`s on the submit path.

#### `PiRpcService` changes

**`_ensureRunning()`** — extract the spawn-and-wire block currently inline in `streamEdit` into a shared helper. Both `streamEdit` and `warmUp` call it.

**`_processLine(String)`** — replaces the inline lambda in `_stdoutSub`. Adds one routing branch before forwarding. During active streaming `_pendingCommands` is always empty so the branch is a no-op:

```dart
void _processLine(String line) {
  final Map<String, dynamic> event;
  try { event = jsonDecode(line); } catch (_) { return; }
  if (event['type'] == 'response' && event['id'] is String) {
    _pendingCommands.remove(event['id'] as String)?.complete(event);
    return; // do NOT forward to _lineController
  }
  _lineController?.add(line);
}
```

**`sendCommand(Map) → Future<Map>`** — sends a command with a fresh `id`, registers a `Completer`, awaits the response with a 5 s timeout. Used for `get_available_models` and `get_state` at popup open. Throws `PiRpcError` on timeout or `success: false`.

**`warmUp() → Future<void>`** — one line: `_ensureRunning()`.

**`dispose()`** — before existing cleanup: complete any pending completers with an error so callers don't hang.

**`streamEdit()`** — gains three optional params (`modelProvider`, `modelId`, `thinkingLevel = 'off'`). Before `new_session`:

```dart
if (modelId != null)
  proc.stdin.writeln(jsonEncode({'type': 'set_model',
      'provider': modelProvider, 'modelId': modelId}));
proc.stdin.writeln(jsonEncode({'type': 'set_thinking_level', 'level': thinkingLevel}));
// always sent — Pi ignores it for non-reasoning models
```

`set_model` and `set_thinking_level` failures are **non-fatal**: Pi falls back to its current model/level and the prompt still runs. The error is stored in a `modelSwitchError` local variable and persisted to `_lastModelSwitchError` after `agent_end`. Callers read `lastModelSwitchError` after the stream ends to surface a warning without aborting the edit.

```dart
if (type == 'response') {
  if (event['command'] == 'set_model' && event['success'] != true)
    modelSwitchError = event['error'] ?? 'set_model failed';
  if (event['command'] == 'set_thinking_level' && event['success'] != true)
    modelSwitchError ??= event['error'] ?? 'set_thinking_level failed';
  if (event['command'] == 'prompt' && event['success'] != true) ...
  continue;
}
```

#### `EditorScreen` changes

Five new fields:

```dart
List<Map<String, dynamic>> _availableModels = [];
bool _modelsLoading = false;
String? _selectedProvider;
String? _selectedModelId;   // null = use Pi's current model
String _thinkingLevel = 'off'; // seeded from Pi's live state on first open
```

`_normaliseLevel` maps Pi's full level range to the four UI values:

```dart
static String _normaliseLevel(String level) => switch (level) {
  'low' || 'minimal' => 'low',
  'medium'           => 'medium',
  'high' || 'xhigh'  => 'high',
  _                  => 'off',
};
```

`_openAiPrompt` runs three parallel calls on first open:

```dart
Future.wait<dynamic>([
  _piRpcService.sendCommand({'type': 'get_available_models'}),
  _piRpcService.sendCommand({'type': 'get_state'}),
  PiRpcService.loadEnabledModelPatterns(),
]).then((results) {
  // filter models, seed _thinkingLevel via _normaliseLevel(piLevel)
});
```

`_submitAiPrompt` passes three params to `streamEdit` and checks `lastModelSwitchError`:

```dart
await for (final chunk in _piRpcService.streamEdit(
  documentText: docText, editTarget: editTarget, userInstruction: prompt,
  modelProvider: _selectedProvider, modelId: _selectedModelId,
  thinkingLevel: _thinkingLevel,
)) { ... }
final switchErr = _piRpcService.lastModelSwitchError;
if (switchErr != null && mounted) setState(() => _errorBanner = 'Model switch failed: $switchErr');
```

`AiPromptPopup` receives one data object + two callbacks:

```dart
AiPromptPopup(
  modelSettings: AiModelSettings(
    availableModels: _availableModels, loading: _modelsLoading,
    selectedModelId: _selectedModelId, thinkingLevel: _thinkingLevel,
  ),
  onModelChanged: (provider, modelId) => setState(() {
    _selectedProvider = provider; _selectedModelId = modelId;
  }),
  onThinkingLevelChanged: (level) => setState(() => _thinkingLevel = level),
)
```

#### `AiPromptPopup` changes

Three new parameters:

```dart
final AiModelSettings? modelSettings;
final void Function(String provider, String modelId)? onModelChanged;
final void Function(String level)? onThinkingLevelChanged;
```

Footer row added below the `TextField` (only rendered when `modelSettings != null`):

```dart
const Divider(height: 1),
SizedBox(height: 32, child: Row(children: [
  _ModelPicker(settings: settings, onChanged: widget.onModelChanged),
  const Spacer(),
  _ThinkingPicker(level: settings.thinkingLevel, onChanged: widget.onThinkingLevelChanged),
])),
```

`_ModelPicker`, `_ThinkingPicker`, and `AiModelSettings` are defined at the bottom of `ai_prompt_popup.dart` — all small enough to stay inline, no new files.

`_ThinkingPicker` is a `DropdownButton<String>` matching `_ModelPicker`'s style. It is shown only when the effective model (selected model, else first visible model) has `reasoning: true`. Items: `Thinking off · Low thinking · Medium thinking · High thinking`.

#### Changes

| File                   | What changes                                                                                                                                                                                                                                   |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pi_rpc_service.dart`  | Extract `_ensureRunning()`; add `_processLine()`, `_pendingCommands`, `_cmdCounter`, `sendCommand()`, `warmUp()`; update `dispose()`; add 3 params to `streamEdit()` (no `modelSupportsThinking`); always send `set_thinking_level`            |
| `editor_screen.dart`   | 5 fields + `_normaliseLevel()`; `_openAiPrompt` 3-parallel fetch + `get_state` seed; `_submitAiPrompt` passes 3 params; `AiPromptPopup` gets `AiModelSettings` (4 fields) + 2 callbacks                                                        |
| `ai_prompt_popup.dart` | 3 new params; `AiModelSettings` (5 fields: includes `selectedProvider`, no `modelSupportsThinking`); footer `Divider` + `Row`; `_ModelPicker` uses provider/id composite keys; `_ThinkingPicker` shown when effective model supports reasoning |

#### Phase 3.9 task checklist

- [x] `PiRpcService`: extract `_ensureRunning() → Future<Process>`
- [x] `PiRpcService`: add `_processLine(String)` — routes id-tagged responses to `_pendingCommands`, forwards everything else to `_lineController`
- [x] `PiRpcService`: add `_pendingCommands` map and `_cmdCounter` field
- [x] `PiRpcService`: add `sendCommand(Map) → Future<Map>` with 5 s timeout
- [x] `PiRpcService`: add `warmUp() → Future<void>`
- [x] `PiRpcService`: update `dispose()` — complete pending completers with error before clearing
- [x] `PiRpcService`: add `modelProvider`, `modelId`, `thinkingLevel = 'off'` params to `streamEdit()`; always send `set_thinking_level`; handle responses in event loop
- [x] `EditorScreen`: add 5 fields + `_normaliseLevel()` static helper
- [x] `EditorScreen`: `_openAiPrompt` — 3-parallel fetch (`get_available_models` + `get_state` + `loadEnabledModelPatterns`); seed model + thinking level
- [x] `EditorScreen`: `_submitAiPrompt` — pass 3 params to `streamEdit`; check `lastModelSwitchError`
- [x] `EditorScreen`: pass `AiModelSettings` (4 fields) + 2 callbacks to `AiPromptPopup`
- [x] `AiPromptPopup`: add `AiModelSettings` data class
- [x] `AiPromptPopup`: add `modelSettings`, `onModelChanged`, `onThinkingLevelChanged` parameters
- [x] `AiPromptPopup`: add footer `Divider` + `Row` below `TextField`
- [x] `AiPromptPopup`: add private `_ModelPicker` widget (`···` while loading, `DropdownMenu` when loaded)
- [x] `AiPromptPopup`: add private `_ThinkingPicker` widget (`DropdownButton<String>`, 4 entries), shown only when effective model supports reasoning

---

### Phase 3.10 — Popup keyboard shortcuts & focus restoration

**End state:** after picking a model or thinking level the text field regains focus automatically. Two additional keyboard shortcuts let the user change model and thinking level without touching the mouse.

#### Focus restoration

After the `DropdownButton` route closes, Flutter returns focus to the app root rather than the `TextField`. Fix: both pickers accept a `VoidCallback onFocusBack` which they call at the end of their `onChanged` handler. `_AiPromptPopupState` supplies `() => _textFieldFocusNode.requestFocus()`.

#### `Ctrl+P` — cycle model forward

Handled in the existing `Focus.onKeyEvent` that wraps the `TextField` (same node that already intercepts Enter / Escape / arrow history).

- If `availableModels` is empty or still loading → ignore (key falls through)
- Find the index of `selectedModelId` in the list; treat `null` / not-found as `-1`
- Next index = `(current + 1) % length`
- Call `widget.onModelChanged(provider, id)` for the new entry
- Return `KeyEventResult.handled` — stops the event before it reaches any app-level `Ctrl+P` binding

#### `Shift+Tab` — cycle thinking level forward

Same `Focus.onKeyEvent` handler, checked before Flutter's built-in Tab/focus-traversal logic.

- Find index of `thinkingLevel` in the 4-item level list
- Next index = `(current + 1) % 4`
- Call `widget.onThinkingLevelChanged(nextLevel)`
- Return `KeyEventResult.handled` — prevents Shift+Tab from moving focus out of the popup

Cycle order: `off → low → medium → high → off → …`

#### Changes

| File                   | What changes                                                                                                                            |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `ai_prompt_popup.dart` | `_ModelPicker` + `_ThinkingPicker` gain `onFocusBack`; `_AiPromptPopupState` passes it; `Focus.onKeyEvent` gains `Ctrl+P` + `Shift+Tab` |

#### Phase 3.10 task checklist

- [x] `_ModelPicker`: add `VoidCallback? onFocusBack`; call after `onChanged`
- [x] `_ThinkingPicker`: add `VoidCallback? onFocusBack`; call after `onChanged`
- [x] `_AiPromptPopupState.build()`: pass `onFocusBack: _textFieldFocusNode.requestFocus` to both pickers
- [x] `Focus.onKeyEvent`: add `Ctrl+P` → cycle model forward (wrap), return `handled`
- [x] `Focus.onKeyEvent`: add `Shift+Tab` → cycle thinking level forward (wrap), return `handled`

---

### Phase 3.11 — Bug fix: `get_state` seeding + model list regression

**Symptoms:**

1. Thinking level dropdown was not seeded from Pi's live state on first open — it always started at the hardcoded default.
2. After adding `get_state` to the fetch, the model list disappeared entirely.

**Root causes:**

1. `get_state` was not called on popup open, so `_thinkingLevel` never reflected Pi's actual state.

2. `get_state` was added to `Future.wait` without error isolation. `Future.wait` fails fast — if `get_state` throws (timeout, Pi not ready, `success: false`), the entire `Future.wait` rejects, `catchError` fires, and `_availableModels` is never populated → model list shows nothing.

**Fixes:**

- Added `get_state` as a second entry in the `Future.wait` inside `_openAiPrompt`, wrapped in `.catchError((_) => <String, dynamic>{})` so a failure returns an empty map rather than rejecting the whole wait. When `get_state` fails the models still load; `_thinkingLevel` stays at its default `'off'`.
- When `get_state` succeeds, `_thinkingLevel` is seeded via `_normaliseLevel(piLevel)`. If Pi's current model is in the filtered list, `_selectedModelId` and `_selectedProvider` are also seeded.
- `streamEdit()` `modelSupportsThinking` param removed; `set_thinking_level` always sent (Pi ignores it for non-reasoning models).
- `_thinkingLevel` default changed from `'medium'` to `'off'`.
- Thinking visibility moved to **effective-model derivation in popup**: compute the effective model as `selectedProvider/selectedModelId` when present, otherwise first visible model (same fallback as dropdown). Show `_ThinkingPicker` only when that model has `reasoning: true`.
- `_ModelPicker` switched to provider/id composite keys for stable selection (`provider/modelId`) and to avoid collisions when two providers expose models with the same `id`.
- `Ctrl+P` cycling also uses the effective model index, so "next" is relative to what the dropdown currently shows even when there is no explicit selection yet.
- `Shift+Tab` gating uses the same effective-model reasoning check as footer visibility.

#### Changes

| File                   | What changes                                                                                                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pi_rpc_service.dart`  | Remove `modelSupportsThinking` param from `streamEdit()`; always send `set_thinking_level`; default `thinkingLevel = 'off'`                                                   |
| `editor_screen.dart`   | Add `get_state` (error-isolated) to `Future.wait`; seed `_thinkingLevel`; seed `_selectedProvider` + `_selectedModelId` when Pi's current model exists in filtered list       |
| `ai_prompt_popup.dart` | Derive effective model from selection/fallback; gate `_ThinkingPicker` + `Shift+Tab` on effective model `reasoning`; switch model picker values to provider/id composite keys |

#### Checklist

- [x] `PiRpcService.streamEdit()`: remove `modelSupportsThinking` param; always send `set_thinking_level`; default `'off'`
- [x] `EditorScreen`: add `get_state` to `Future.wait` wrapped in `.catchError`; seed `_thinkingLevel`; seed `_selectedProvider` + `_selectedModelId` when available
- [x] `EditorScreen`: change `_thinkingLevel` default to `'off'`
- [x] `AiPromptPopup`: derive effective model (`selected model` else `first visible`) and use it for thinking visibility and `Shift+Tab` gating
- [x] `AiPromptPopup`: use provider/id composite keys in `_ModelPicker`; use effective-model index for `Ctrl+P` next

---

### Phase 3.12 — Insert mode for `Ctrl+K` with no selection

**End state:** `Ctrl+K` with no selection inserts the AI output at the cursor position instead of replacing the entire document.

#### Changes

| File                  | What changes                                                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `pi_rpc_service.dart` | When `editTarget` is empty, use an insert-mode prompt (before-cursor / after-cursor context) instead of the edit-mode prompt |
| `editor_screen.dart`  | `editTarget = ''` when selection is collapsed; `_acceptDiff` inserts at `sel.start` instead of replacing the whole document  |

#### Checklist

- [x] `EditorScreen._submitAiPrompt`: change `editTarget` to `''` when `sel.isCollapsed`
- [x] `EditorScreen._submitAiPrompt`: change `editTarget` to `''` when `sel.isCollapsed`
- [x] `EditorScreen._acceptDiff`: when `sel.isCollapsed`, insert at cursor (`docText.substring(0, sel.start) + result + docText.substring(sel.start)`)
- [x] `PiRpcService.streamEdit`: when `editTarget` is empty, send insert-mode prompt (before/after cursor context); otherwise send existing edit-mode prompt

---

### Phase 3.13 — Paragraph auto-selection for `Ctrl+K` with no selection

**End state:** `Ctrl+K` with no selection on a non-blank line auto-selects the surrounding paragraph and enters edit mode. Cursor on a blank line falls back to insert mode (unchanged from 3.12).

#### Changes

| File                 | What changes                                                                                                        |
| -------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `editor_screen.dart` | Add `_paragraphRangeAt` static helper; expand `_snapshotSelection` to paragraph range at start of `_submitAiPrompt` |

#### Checklist

- [x] `EditorScreen._paragraphRangeAt`: static helper returning `(start, end)?` for the paragraph at a given offset; returns null on blank lines
- [x] `EditorScreen._submitAiPrompt`: when `_snapshotSelection.isCollapsed`, call `_paragraphRangeAt`; if non-null, mutate `_snapshotSelection` to cover the paragraph before the normal edit path runs

### Phase 3.14 — Insert-mode prompt refinement and newline fix

**End state:** Insert-mode prompts use an inline `[CURSOR]` marker instead of a before/after split; accepting the diff wraps the result with blank-line separators so paragraphs stay properly spaced.

#### Changes

| File                  | What changes                                                                                                                                                                             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pi_rpc_service.dart` | `_buildPromptMessage` insert path: embed `[CURSOR]` directly in the document string; instruct the model to omit surrounding blank lines                                                  |
| `editor_screen.dart`  | `_acceptDiff` collapsed branch: use `'\n' + result.trim() + '\n'` so the existing `\n` on each side of the blank line becomes a `\n\n` paragraph gap; update cursor position accordingly |

#### Checklist

- [x] `PiRpcService._buildPromptMessage`: replace before/after split framing with single `Document:\n$before[CURSOR]$after` string; update IMPORTANT instruction
- [x] `EditorScreen._acceptDiff`: collapsed branch uses `trimmed = result.trim()`; inserts `'\n' + trimmed + '\n'`; `newCursorPos = sel.start + 1 + trimmed.length`

---

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

| Need                       | Solution                                                                                                                                                           |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| State management           | `ChangeNotifier` + `ListenableBuilder` (built into Flutter)                                                                                                        |
| Tab IDs                    | Incrementing integer counter (`_nextTabId`)                                                                                                                        |
| App data directory         | `dart:io` + `Platform.environment['APPDATA']` (Windows)                                                                                                            |
| Text diffing (Phase 3)     | Simple line-by-line diff with `dart:core`                                                                                                                          |
| JSON serialization         | `dart:convert`                                                                                                                                                     |
| File read/write            | `dart:io`                                                                                                                                                          |
| AI integration (Phase 3.7) | `dart:io Process.start` — spawn `pi --mode rpc` as a child process; read JSON lines from stdout; write JSON commands to stdin. No HTTP client, no API keys in-app. |
