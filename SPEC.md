# Clankpad — Specification

A minimalist Notepad-style text editor with multi-tab support, built in Flutter for desktop (Windows as primary target).

---

## 1. Overview

Clankpad is a simple desktop app: one window, a tab bar, and a text area. No distractions. The basic flow is:

- On launch, one empty tab is ready to type in.
- The user can create more tabs, write in each one, save, open files, and close tabs.

---

## 2. Features

### 2.1 Tabs

| Action           | Description                                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------------------------- |
| `Ctrl+N`         | Creates a new empty tab                                                                                         |
| Click `+`        | Creates a new empty tab (mouse-friendly alternative to `Ctrl+N`)                                                |
| Click on tab     | Switches to that tab                                                                                            |
| Click `×` on tab | Closes that tab (prompts confirmation if there are unsaved changes)                                             |
| Tab title        | Shows the file name; if no file is assigned, shows `Untitled` with a number (`Untitled 1`, `Untitled 2`, etc.) |
| Dirty indicator  | A dot `●` in the title when there are unsaved changes                                                           |

**Rule:** If the last tab is closed, the app automatically creates a new empty tab (there is always at least one tab).

### 2.2 Text Area

- Plain text editor (no formatting).
- Monospaced font.
- Vertical scroll when content exceeds the screen.
- The area fills all available space below the tab bar.

### 2.3 Open File _(Phase 2)_

| Action   | Method                                                                                              |
| -------- | --------------------------------------------------------------------------------------------------- |
| `Ctrl+O` | Opens the system file picker dialog                                                                 |
| Behavior | If the active tab is empty and clean → load the file there. Otherwise → open the file in a new tab |

### 2.4 Save File _(Phase 2)_

| Action         | Method                                                       |
| -------------- | ------------------------------------------------------------ |
| `Ctrl+S`       | Saves the current file. If it has no path → opens "Save As" |
| `Ctrl+Shift+S` | Always opens "Save As" (allows changing name/location)       |

### 2.5 Inline AI Edit (`Ctrl+K`)

A lightweight inline prompt popup, inspired by Cursor's inline edit feature.

**Trigger:**
- `Ctrl+K` with text selected → opens the popup; the selected text is the **edit target**.
- `Ctrl+K` with no selection → the entire document content is treated as the edit target (equivalent to selecting all).

**Popup behavior:**
- A small floating input box appears near the selected text. If there is no selection, the popup appears at the **center of the editor area**.
- The user types a natural-language prompt (e.g. *"make this more formal"*, *"fix the grammar"*).
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

### 2.6 Menu Bar _(optional / phase 2)_

`File` menu with: New, Open, Save, Save As, Close Tab, Exit.

---

## 3. UI Structure

```
┌─────────────────────────────────────────────────────┐
│  [Untitled 1 ●] [×]  [notes.txt] [×]  [+]          │  ← Tab bar
├─────────────────────────────────────────────────────┤
│                                                     │
│  (text area — fills the rest of the window)         │
│                                                     │
│                                                     │
└─────────────────────────────────────────────────────┘
```

- **Tab bar:** horizontal row of tabs with a `+` button at the end to create a new tab.
- **Text area:** expanded `TextField` or `EditableText`, no borders, comfortable padding.

---

## 4. Data Model

Each tab is represented by an `EditorTab` object:

```dart
class EditorTab {
  final String id;                    // unique UUID
  String? filePath;                   // null if the file has not been saved yet
  String title;                       // file name or "Untitled N"
  String savedContent;                // content at last save (to detect changes)
  final TextEditingController controller; // source of truth for current text

  // isDirty compares the controller's live text against the last saved snapshot
  bool get isDirty => controller.text != savedContent;
}
```

The global app state manages:
- `List<EditorTab> tabs`
- `int activeTabIndex`

---

## 5. Expected Dependencies

| Package                          | Purpose                                         |
| -------------------------------- | ----------------------------------------------- |
| `file_selector`                  | Native open/save file dialogs                   |
| `provider` or `flutter_riverpod` | State management                                |
| `diff_match_patch`               | Text diffing for the Phase 2 accept/reject view |

---

## 6. Project File Structure

```
lib/
  main.dart                  # Entry point, MaterialApp
  models/
    editor_tab.dart          # EditorTab model
  state/
    editor_state.dart        # ChangeNotifier / StateNotifier with tab list
  widgets/
    tab_bar.dart             # Custom tab bar
    tab_item.dart            # Individual tab (title + close button)
    editor_area.dart         # Text area
    ai_prompt_popup.dart     # Floating Ctrl+K prompt input
    ai_diff_view.dart        # Phase 2: inline diff accept/reject overlay
  screens/
    editor_screen.dart       # Main screen composing everything
  services/
    ai_service.dart          # AI integration placeholder (Pi via MCP — TBD)
```

---

## 7. Development Phases

### Phase 1 — Core (MVP)

- [ ] `EditorTab` model and basic state
- [ ] UI: tab bar + text area
- [ ] Create tab (`Ctrl+N` and `+` button)
- [ ] Close tab (with minimum 1 tab rule)
- [ ] Unsaved changes indicator (`●`)
- [ ] `Ctrl+K` popup with prompt input (`Enter` to submit, `Shift+Enter` for newline, `Escape` to dismiss)
- [ ] AI stub: direct replace of selected text (or full content) with AI output (no diff yet)

### Phase 2 — File I/O + AI Diff

- [ ] Open file (`Ctrl+O`)
- [ ] Save (`Ctrl+S`)
- [ ] Save As (`Ctrl+Shift+S`)
- [ ] Confirmation dialog when closing a dirty tab
- [ ] `Ctrl+K` diff view: show old vs new text, Accept (`Tab` / `Ctrl+Enter`) or Reject (`Escape`)

### Phase 3 — Polish

- [ ] Window title reflects the active file
- [ ] Native app menu (File menu on Windows/macOS)
- [ ] Font size adjustment
- [ ] Light / dark theme
