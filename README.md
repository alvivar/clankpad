# Clankpad

A minimalist, distraction-free text editor with multi-tab support and inline AI editing. Built with Flutter for Windows desktop.

---

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart SDK ^3.11.0)
- Windows (primary target; Linux/macOS may work but are untested)
- _(Optional, for AI features)_ [Node.js](https://nodejs.org/) + [Pi coding agent](https://www.npmjs.com/package/@mariozechner/pi-coding-agent)
    - Install: `npm install -g @mariozechner/pi-coding-agent`
    - Authenticate/configure once (e.g. run `pi /login`)

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

```
┌───────────────────────────────────────────────────────┐
│  [Untitled 1 ●] [×]  [notes.txt] [×]  [+]   ← scroll  │  ← Tab bar
├─────────────────────────────────────────────────────  ┤
│  ┌─────────────────────────────────────────────┐      │
│  │  Ctrl+K prompt popup (when active)          │      │  ← AI overlay
│  └─────────────────────────────────────────────┘      │
│                                                       │
│  Text area — fills the rest of the window             │
│  (vertical scroll, word wrap on)                      │
│                                                       │
└───────────────────────────────────────────────────────┘
```

---

## Features & Usage

### Tabs

| Action                             | Result                    |
| ---------------------------------- | ------------------------- |
| `Ctrl+N` or click **`+`**          | Open a new empty tab      |
| Click a tab                        | Switch to that tab        |
| `Ctrl+W` or click **`×`** on a tab | Close the active/that tab |

**Tab titles** show the file name. Unsaved (new) tabs are named _Untitled 1_, _Untitled 2_, etc. — the counter always increments and is never reused across the session.

**Dirty indicator** — a dot `●` appears in the tab title whenever the tab has unsaved changes.

**Tab bar scrolling** — when you have more tabs than fit the window width, the tab bar scrolls horizontally.

**Minimum one tab** — closing the last tab automatically opens a fresh empty tab.

**Closing a tab with unsaved changes** prompts a confirmation dialog:

- **Save** — saves (opens _Save As_ if the file has no path), then closes the tab.
- **Don't Save** — discards changes and closes the tab.
- **Cancel** — keeps the tab open.

---

### Text Area

- Plain text, monospaced font.
- Word wrap **on** by default; scrolls vertically when content exceeds the window height.
- Fills all available space below the tab bar.

---

### File Operations

| Shortcut       | Action                                                    |
| -------------- | --------------------------------------------------------- |
| `Ctrl+O`       | Open a file via the system file picker                    |
| `Ctrl+S`       | Save the current file (opens _Save As_ if no path is set) |
| `Ctrl+Shift+S` | Save As — always prompts for a file name/location         |

**Opening a file:**

- If the active tab is empty and unmodified, the file loads there.
- Otherwise, it opens in a new tab.
- If the file is already open in another tab, Clankpad switches to that tab instead of opening a duplicate.

**Save errors** (permissions, disk full, locked file, etc.) show a modal error dialog. The tab stays open and dirty — no data is lost silently.

---

### Session Persistence (Hot Exit)

Clankpad never loses your work. Every change is saved to a session file automatically.

- **Auto-save** — the session is saved to disk 500 ms after your last change (debounced), so continuous typing never hammers the disk.
- **On close** — any pending save is flushed synchronously before the app exits.
- **On reopen** — all tabs are restored exactly as you left them: content, file paths, and which tab was active.

**What gets restored:**

| Tab state                          | Restored as                       |
| ---------------------------------- | --------------------------------- |
| File-backed, saved (clean)         | Re-read from disk                 |
| File-backed, unsaved edits (dirty) | Edits and file path both restored |
| Untitled (no file)                 | Content always restored           |

**If a file has moved or been deleted since last session:**

- If the tab had unsaved edits → content is restored from the session; a notice is shown so you can save it to a new location.
- If the tab was clean (no unsaved edits) → the tab is skipped and a notification is shown.

---

### Inline AI Edit (`Ctrl+K`)

A floating prompt popup for AI-assisted text editing, powered by **Pi** (`pi --mode rpc`).

Clankpad does **not** talk to model APIs directly and stores no API keys. Pi owns auth + model configuration. For safety, Pi is launched with tools disabled (text-only) — it only sees the current document text and your selected edit target.

**AI setup (optional):**

```bash
npm install -g @mariozechner/pi-coding-agent
pi /login
```

If Pi isn't available (not installed or not on `PATH`), `Ctrl+K` will show a dismissible error banner and the editor remains usable.

**How to use:**

1. **Select text** you want to edit, then press `Ctrl+K` — the AI will transform just that selection.
2. Press `Ctrl+K` **with no selection** — the AI will work on the entire document.
3. Type your instruction in the popup (e.g. _"fix the grammar"_, _"make this more formal"_).
4. Press `Enter` to submit.

**Inside the popup:**

| Key           | Action                                                                            |
| ------------- | --------------------------------------------------------------------------------- |
| `Enter`       | Submit the prompt                                                                 |
| `Shift+Enter` | Insert a newline in the prompt                                                    |
| `Escape`      | Dismiss the popup without making changes                                          |
| `↑` / `↓`     | Browse prompt history (cursor must be on the first / last line)                   |
| `Ctrl+P`      | Cycle the model (when the model list is loaded)                                   |
| `Shift+Tab`   | Cycle thinking level (off → low → medium → high; only shown for reasoning models) |

**Model & thinking level:** the popup footer lets you pick an AI model and (for reasoning-capable models) a thinking level. The model list comes from Pi and can be filtered via Pi's `enabledModels` setting (`~/.pi/agent/settings.json`). Model/thinking selection and prompt history are kept in-memory for the current app run.

**While the AI request is running**, the editor is locked (read-only). Before the first tokens arrive, a thin progress bar appears below the tab bar with **Cancel (Esc)**.

**Reviewing the result** — the response streams into a “Before / After” diff card:

- Press `Tab` or `Ctrl+Enter` to **accept** the change.
- Press `Escape` to **reject** and keep the original.

The editor stays read-only until you accept or reject.

---

## Keyboard Shortcuts

### Global

| Shortcut       | Action           |
| -------------- | ---------------- |
| `Ctrl+N`       | New tab          |
| `Ctrl+W`       | Close active tab |
| `Ctrl+O`       | Open file        |
| `Ctrl+S`       | Save             |
| `Ctrl+Shift+S` | Save As          |
| `Ctrl+K`       | AI inline edit   |

### Ctrl+K prompt popup

| Key           | Action                                           |
| ------------- | ------------------------------------------------ |
| `Enter`       | Submit prompt                                    |
| `Shift+Enter` | Insert newline                                   |
| `Escape`      | Dismiss popup                                    |
| `↑` / `↓`     | Prompt history (first / last line only)          |
| `Ctrl+P`      | Cycle model                                      |
| `Shift+Tab`   | Cycle thinking level (off → low → medium → high) |

### AI diff review

| Key                  | Action         |
| -------------------- | -------------- |
| `Tab` / `Ctrl+Enter` | Accept AI edit |
| `Escape`             | Reject AI edit |

> While the progress stripe is visible (before the diff opens), `Escape` cancels the in-flight request.

---

## Session File Location

The session is stored at:

```
%APPDATA%\Clankpad\session.json
```

You can delete this file to reset the session (all tabs will be lost).

---

## What's Coming

- [ ] Window title reflects the active file
- [ ] No-wrap + horizontal scroll mode (`Alt+Z` toggle)
- [ ] Native File menu (New, Open, Save, Save As, Exit)
- [ ] Font size adjustment
- [ ] Light / dark theme toggle
- [ ] True inline `Ctrl+K` popup positioning near the cursor
