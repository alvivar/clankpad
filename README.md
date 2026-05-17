# Clankpad

A minimalist, distraction-free plain-text editor with multi-tab support, hot-exit session restore, find, and inline AI editing. Built with Flutter for desktop, with Windows as the primary target.

---

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart SDK ^3.11.0)
- Windows (primary target; macOS/Linux runners exist but are less tested)
- Optional, for AI features:
  - [Node.js](https://nodejs.org/) + [Pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
  - and/or [Claude Code](https://docs.anthropic.com/claude-code)

Pi setup example:

```bash
npm install -g @earendil-works/pi-coding-agent
pi /login
```

Claude Code must be installed as `claude` on `PATH` and authenticated separately.

---

## Running the App

```bash
# Install dependencies
flutter pub get

# Run in debug mode
flutter run -d windows

# Build a release executable
flutter build windows
# Output: build\windows\x64\runner\Release\clankpad.exe
```

---

## Interface Overview

```text
┌───────────────────────────────────────────────────────┐
│  [Untitled 1 ●] [×]  [notes.txt] [×]  [+]   ← scroll  │  ← Tab bar
├───────────────────────────────────────────────────────┤
│  Error banner / AI progress / Find bar when visible   │
├───────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────┐      │
│  │  Ctrl+K prompt popup or AI diff overlay     │      │
│  └─────────────────────────────────────────────┘      │
│                                                       │
│  Text area — fills the rest of the window             │
│  (vertical scroll, word wrap on)                      │
└───────────────────────────────────────────────────────┘
```

On Windows and macOS the native runner opens the window centered at about 80% width × 90% height of the usable screen area.

---

## Features & Usage

### Tabs

| Action                                       | Result               |
| -------------------------------------------- | -------------------- |
| `Ctrl+N` or click **`+`**                    | Open a new empty tab |
| Click a tab                                  | Switch to that tab   |
| `Ctrl+W`, click **`×`**, or middle-click tab | Close a tab          |

- File-backed tabs use the file name as their title.
- New unsaved tabs are named `Untitled N`; the counter increments and is never reused.
- A dot `●` marks tabs with unsaved changes.
- The tab bar scrolls horizontally when tabs exceed the available width.
- Closing the last tab exits the app if that tab is an empty clean untitled tab; otherwise dirty-close rules still apply.

Closing a dirty tab prompts:

- **Save** — writes the file, or opens Save As for untitled tabs, then closes.
- **Don't Save** — discards changes and closes.
- **Cancel** — keeps the tab open.

---

### Text Editing

- Plain text, monospaced font.
- Word wrap is on.
- Vertical scrolling is enabled.
- `Tab` indents by 4 spaces; with no selection it inserts spaces to the next tab stop.
- `Shift+Tab` outdents selected lines or the current line's indentation.
- `Alt+↑` / `Alt+↓` moves the current line or selected block up/down one line.

---

### Find (`Ctrl+F`)

The find bar appears between the tab bar and editor.

- Search is case-insensitive.
- Matches update live and are highlighted in the editor.
- Counter shows `N of M` or `No results`.
- Navigation wraps around.
- If the editor has a non-collapsed single-line selection when Find opens, that text pre-fills the query.

| Key                        | Action         |
| -------------------------- | -------------- |
| `Enter` / `F3`             | Next match     |
| `Shift+Enter` / `Shift+F3` | Previous match |
| `Escape`                   | Close find bar |

---

### File Operations

| Shortcut       | Action                                           |
| -------------- | ------------------------------------------------ |
| `Ctrl+O`       | Open a file via the system file picker           |
| `Ctrl+S`       | Save the current file; Save As if no path is set |
| `Ctrl+Shift+S` | Save As — always asks for a file name/location   |

Opening a file:

- If the file is already open, Clankpad switches to the existing tab.
- If the active tab is empty, untitled, and clean, the file loads there.
- Otherwise the file opens in a new tab.

Save/open errors show a dialog or banner and keep the tab/data intact.

---

### Session Persistence (Hot Exit)

Clankpad continuously saves session state so closing the app does not lose work.

- Changes are debounced and written after 500 ms.
- On app exit, pending session writes are flushed synchronously.
- On reopen, tabs, file paths, unsaved text, active tab, and AI provider/model preferences are restored.
- Clean file-backed tabs are re-read from disk.
- Dirty file-backed tabs restore unsaved content from the session.
- Missing/deleted files produce a startup notice instead of silently losing content.

Session file:

```text
%APPDATA%\Clankpad\session.json
```

On non-Windows platforms the fallback location is `./session.json`.

---

## Inline AI Edit (`Ctrl+K`)

`Ctrl+K` opens a floating prompt for AI-assisted text editing. Clankpad does not store API keys or call model APIs directly; it shells out to a local AI backend.

Registered providers:

| Provider    | Backend                                              |
| ----------- | ---------------------------------------------------- |
| Pi          | Long-lived `pi --mode rpc` subprocess                |
| Claude Code | One-shot `claude -p --output-format stream-json` run |

Both providers are launched with a text-editor-specific system prompt. Pi is launched with tools disabled; Claude Code is run without session persistence.

### Edit target behavior

When `Ctrl+K` opens, Clankpad snapshots the active tab:

- If text is selected, the AI edits that selection.
- If there is no selection and the caret is on a non-blank line, the surrounding paragraph is edited.
- If the caret is on a blank line, the AI output is inserted at the cursor.

The edit target is highlighted until the prompt is dismissed or the diff is accepted/rejected.

### Prompt popup keys

| Key           | Action                                                           |
| ------------- | ---------------------------------------------------------------- |
| `Enter`       | Submit prompt                                                    |
| `Shift+Enter` | Insert newline in prompt                                         |
| `Escape`      | Dismiss popup                                                    |
| `↑` / `↓`     | Browse prompt history when cursor is on first/last line          |
| `Ctrl+Tab`    | Cycle AI provider                                                |
| `Ctrl+P`      | Cycle model                                                      |
| `Shift+Tab`   | Cycle thinking level when the effective model supports reasoning |

Prompt history is in-memory only and capped at 50 entries.

### Streaming and review

After submit:

1. The editor becomes read-only.
2. A thin progress indicator appears below the tab bar.
3. The AI response streams into a unified line-level diff card with `+` / `-` markers and red/green highlighting.
4. The editor remains locked until you accept or reject.

| Key              | Action         |
| ---------------- | -------------- |
| `Ctrl+Enter`     | Accept AI edit |
| `Ctrl+Backspace` | Reject AI edit |

While loading before the diff opens, `Escape` or the Cancel button aborts the in-flight request. Once the diff opens, reject the diff instead.

If an AI provider fails, Clankpad shows a dismissible error banner and unlocks the editor. If the provider errors after partial diff output, the partial diff is automatically rejected so incomplete output cannot be accepted accidentally.

---

## Keyboard Shortcuts

### App-level

| Shortcut       | Action                        |
| -------------- | ----------------------------- |
| `Ctrl+N`       | New tab                       |
| `Ctrl+W`       | Close active tab              |
| `Ctrl+O`       | Open file                     |
| `Ctrl+S`       | Save                          |
| `Ctrl+Shift+S` | Save As                       |
| `Ctrl+F`       | Find                          |
| `Ctrl+K`       | AI inline edit                |
| `Alt+↑`        | Move line/block up            |
| `Alt+↓`        | Move line/block down          |
| `Escape`       | Cancel AI request before diff |

### Editor-local

| Shortcut    | Action            |
| ----------- | ----------------- |
| `Tab`       | Indent / tab stop |
| `Shift+Tab` | Outdent           |

### AI diff review

| Shortcut         | Action         |
| ---------------- | -------------- |
| `Ctrl+Enter`     | Accept AI edit |
| `Ctrl+Backspace` | Reject AI edit |

---

## Documentation

- Feature backlog: [`FEATURES.md`](FEATURES.md)
- Markdown preview plan: [`docs/plans/markdown-preview.md`](docs/plans/markdown-preview.md)
- Archived implementation spec: [`docs/archive/SPEC.md`](docs/archive/SPEC.md)
- Vendor references: [`docs/vendor/`](docs/vendor/)

---

## What's Coming

See [`FEATURES.md`](FEATURES.md) for the broader wishlist. Current focused plans include:

- AI diff polish — word-level highlighting, side-by-side toggle, and per-hunk accept/reject: [`DIFF_PLAN.md`](DIFF_PLAN.md)
- Markdown preview: [`docs/plans/markdown-preview.md`](docs/plans/markdown-preview.md)
- Status bar, find/replace, line numbers, file watcher, and syntax highlighting
