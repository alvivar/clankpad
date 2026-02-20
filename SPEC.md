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
| Click `×` on tab | Closes that tab (prompts confirmation if there are unsaved changes)                                              |
| Tab title        | Shows the file name; if no file is assigned, shows `Untitled N` with an ever-incrementing counter (never reused) |
| Dirty indicator  | A dot `●` in the title when there are unsaved changes                                                            |

**Tab bar overflow:** When tabs exceed the available width, the tab bar scrolls horizontally.

**Untitled counter:** The counter increments globally and is never reused. Closing "Untitled 2" and opening a new tab produces "Untitled 3", not "Untitled 2" again.

**Rule:** If the last tab is closed, the app automatically creates a new empty tab (there is always at least one tab).

**Closing a dirty tab — confirmation dialog:**
Three options are presented:

- **Save** — saves the file (opens "Save As" if no path) then closes the tab.
- **Don't Save** — discards changes and closes the tab.
- **Cancel** — dismisses the dialog, tab remains open.

### 2.2 Text Area

- Plain text editor (no formatting).
- Monospaced font.
- Long lines produce **horizontal scroll** (no word wrap by default).
- Vertical scroll when content exceeds the screen height.
- The area fills all available space below the tab bar.
- _(Phase 3)_ `Alt+Z` toggles word wrap on/off.

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

### 2.5 Session Persistence _(Phase 2)_

Clankpad implements a **hot exit**: closing the app never causes data loss.

- On every meaningful change (text edit, tab open/close, active tab switch), the session is written to `session.json` in the app's data directory.
- On launch, if `session.json` exists, all tabs are restored: their content, file paths, titles, and which tab was active.

**What gets stored per tab:**

| Tab state | `content` stored? | `savedContent` stored? |
| --- | --- | --- |
| File-backed, **clean** | No — re-read from disk on restore | No — disk content becomes baseline |
| File-backed, **dirty** | Yes — preserves unsaved edits | Yes — needed to correctly recompute `isDirty` on restore |
| Untitled (no file path) | Yes — always | Yes — always |

**Restore logic:**
1. If `content` is present in the session → set the controller to that text. Use `savedContent` to recompute `isDirty`.
2. If `content` is absent → read from `filePath` on disk. That becomes both the controller text and `savedContent` (clean state).
3. If `filePath` no longer exists or is unreadable → fall back to stored `content` if present; otherwise open an error placeholder tab with a clear message.

### 2.6 Inline AI Edit (`Ctrl+K`)

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

**AI context:**

- The AI receives the **full document content** as context so it understands the surrounding text.
- The edit instruction is applied only to the **selected text** (or the whole document if nothing was selected).

**Result (Phase 1 — simple replace):**

- The popup closes, then the selected text (or full content) is replaced directly with the AI output. No diff view.

**Result (Phase 2 — diff view):**

- The popup closes, then a diff view appears inline: old text (struck through / red) vs new text (green).
- The user can **Accept** (`Tab` or `Ctrl+Enter`) or **Reject** (`Escape`) the change.

### 2.7 Menu Bar _(optional / Phase 3)_

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
│   horizontal + vertical scroll)                     │
│                                                     │
└─────────────────────────────────────────────────────┘
```

- **Tab bar:** horizontally scrollable row of tabs with a `+` button at the end.
- **Text area:** expanded `TextField` or `EditableText`, no borders, comfortable padding, both axes scrollable.
- **AI popup:** rendered via `Overlay`, anchored top-center of the editor area.

---

## 4. Data Model

### EditorTab

```dart
class EditorTab {
  final int id;                           // unique incrementing integer
  String? filePath;                       // null if the file has not been saved yet
  String title;                           // file name or "Untitled N"
  String savedContent;                    // content at last save (to detect changes)
  final TextEditingController controller; // single source of truth for current text

  bool get isDirty => controller.text != savedContent;

  // Called by EditorState when the tab is removed.
  void dispose() => controller.dispose();
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

**Controller listener pattern:** When a tab is created, `EditorState` attaches a listener to its `controller` that calls `notifyListeners()` on every text change. When a tab is closed, the listener is removed and `tab.dispose()` is called. This keeps the dirty indicator reactive and prevents memory leaks.

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
            "filePath": "C:/Users/user/Documents/notes.txt",
            "content": null,
            "savedContent": null
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

- Tab `4` (`notes.txt`) is **clean**: `content` is omitted, disk is re-read on restore.
- Tab `5` (`draft.txt`) is **dirty**: both `content` (unsaved edits) and `savedContent` (last save snapshot) are stored so the edited state is fully preserved.
- Tab `3` (`Untitled 3`) has no file path: `content` is always stored.
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
```

This approach correctly intercepts shortcuts even when a `TextField` is focused, since the `Shortcuts` layer sits above the focused widget in the dispatch chain.

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
    editor_tab_item.dart       # Individual tab chip (title + ● + × button)
    editor_area.dart           # Text area (both-axes scrollable)
    ai_prompt_popup.dart       # Floating Ctrl+K prompt input (Overlay)
    ai_diff_view.dart          # Phase 2: inline diff accept/reject overlay
  screens/
    editor_screen.dart         # Main screen: Stack of editor_area + overlays
  services/
    session_service.dart       # Read/write session.json
    ai_service.dart            # AI integration placeholder (Pi via MCP — TBD)
```

---

## 7. Development Phases

### Phase 1 — Core (MVP)

- [ ] `EditorTab` model with `dispose()` and `isDirty`
- [ ] `EditorState` with controller listener pattern and untitled counter
- [ ] UI: scrollable tab bar + text area (horizontal + vertical scroll)
- [ ] Create tab (`Ctrl+N` and `+` button)
- [ ] Close tab (with minimum 1 tab rule)
- [ ] Unsaved changes indicator (`●`)
- [ ] Closing dirty tab: Save / Don't Save / Cancel dialog
- [ ] `Ctrl+K` popup (top-center overlay, `Enter` submit, `Shift+Enter` newline, `Escape` dismiss)
- [ ] AI stub: direct replace of selected text (or full content) with placeholder output

### Phase 2 — File I/O + Persistence + AI Diff

- [ ] Open file (`Ctrl+O`)
- [ ] Save (`Ctrl+S`)
- [ ] Save As (`Ctrl+Shift+S`)
- [ ] Session persistence: write `session.json` on every change, restore on launch
- [ ] `Ctrl+K` diff view: old vs new, Accept (`Tab` / `Ctrl+Enter`) or Reject (`Escape`)

### Phase 3 — Polish

- [ ] Window title reflects the active file
- [ ] `Alt+Z` toggles word wrap
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
| Text diffing (Phase 2) | Simple line-by-line diff with `dart:core`                   |
| JSON serialization     | `dart:convert`                                              |
| File read/write        | `dart:io`                                                   |
