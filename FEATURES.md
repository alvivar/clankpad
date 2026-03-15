# Feature Ideas

Ideas to make Clankpad better, organized by theme. Clankpad is a minimalist quick editor — a programmer's scratchpad that sits alongside AI coding agents like Pi and Claude Code. Every idea here should earn its place: if it doesn't make the "open Clankpad, do the thing, get back to work" loop faster, it doesn't belong.

---

## Editor Essentials

Things any programmer reaches for instinctively. Their absence creates friction; their presence is invisible.

- [ ] **Line numbers** — gutter with line numbers. Essential for referencing positions when talking to AI agents ("fix line 42"). Toggle via setting or always on.
- [ ] **Go to line (`Ctrl+G`)** — popup to jump to a line number. Quick navigation in long files.
- [ ] **Find and replace (`Ctrl+H`)** — extend the existing find bar with a replace field. Support replace-one and replace-all. Regex toggle.
- [ ] **Delete line (`Ctrl+Shift+K`)** — delete the current line (or all lines touched by the selection) without clipboard pollution.
- [ ] **Duplicate line (`Ctrl+Shift+D`)** — duplicate current line or selection downward. Faster than copy-paste for repetitive edits.
- [ ] **Select line (`Ctrl+L`)** — select the current line. Repeated presses extend to the next line. Useful for quickly grabbing blocks to feed to Ctrl+K.
- [ ] **Toggle comment (`Ctrl+/`)** — insert/remove `//` prefix. Detect language from file extension for the comment style (`#`, `--`, `//`, `/* */`). Works on single lines and selections.
- [ ] **Auto-indent on Enter** — match the indentation of the current line when pressing Enter. Optionally increase indent after `{`, `:`, etc.
- [ ] **Bracket auto-close** — typing `(`, `[`, `{`, `"`, `'` inserts the matching closer and places the cursor between them. Type the closer to skip past it instead of doubling.
- [ ] **Smart backspace** — backspace at the start of an indented line removes one indent level (4 spaces) instead of one character. Mirrors Shift+Tab behavior.
- [ ] **Word wrap toggle (`Alt+Z`)** — switch between soft wrap and horizontal scroll. Already planned in SPEC Phase 4, noting here for completeness.

---

## Navigation & Tab Management

Moving between files and within files should be near-instant.

- [ ] **Switch tabs with `Ctrl+Tab` / `Ctrl+Shift+Tab`** — cycle forward/backward through tabs in MRU (most-recently-used) order, like browser tabs.
- [ ] **Go to tab by number (`Ctrl+1`–`Ctrl+9`)** — jump to tab N directly. `Ctrl+9` always goes to the last tab.
- [ ] **Reopen closed tab (`Ctrl+Shift+T`)** — undo the last tab close. Keep a stack of recently closed tabs (path + content + cursor position). Essential for accidental closes.
- [ ] **Tab context menu (right-click)** — Close, Close Others, Close to the Right, Close Saved, Copy Path, Reveal in Explorer. Standard tab context operations.
- [ ] **Tab reordering (drag & drop)** — reposition tabs by dragging. Persisted in session.
- [ ] **Recent files** — track the last N opened files. Accessible via a shortcut or menu. Speeds up reopening files without a full file picker.
- [ ] **Ctrl+D — select next occurrence** — with text selected, pressing Ctrl+D adds the next occurrence to the selection (multi-cursor). Powerful for batch renaming.

---

## AI Workflow

Clankpad's core differentiator. These ideas deepen the AI integration beyond single-shot inline edits.

- [ ] **Prompt templates / quick actions** — save common Ctrl+K instructions as reusable templates ("fix grammar", "add type annotations", "simplify this", "explain this", "translate to English"). Accessible via a dropdown in the Ctrl+K popup or a dedicated shortcut. User-editable list stored in session or a config file.
- [ ] **Multi-tab context for AI** — option to include content from other open tabs as context when submitting a Ctrl+K prompt. For example: "refactor this function using the patterns from [other tab]." A checkbox or @-mention syntax in the prompt field to reference tabs by name.
- [ ] **AI chat sidebar (`Ctrl+Shift+K`)** — a persistent conversation panel alongside the editor. Unlike Ctrl+K (which is a single-shot edit), this is for back-and-forth: "explain this code", "what's the bug here?", "give me three alternatives". Responses stream into the panel; the user can copy or apply snippets into the editor. Keeps the editor clean while having a dialog.
- [ ] **Copy as markdown code block** — select text, right-click or shortcut → copies as ` ```lang\n...\n``` ` with the language inferred from the file extension. Essential for pasting into AI agent prompts, GitHub issues, or chat.
- [ ] **Paste as plain text (`Ctrl+Shift+V`)** — strip formatting when pasting from browsers, docs, etc. Always plain text. (Standard `Ctrl+V` already does this in a plain TextField, but worth making explicit if rich paste ever becomes an issue.)
- [ ] **AI diff: partial accept** — in the diff view, let the user accept individual lines or hunks rather than all-or-nothing. Click a line in the "After" pane to toggle it in/out of the accepted set.
- [ ] **AI edit history / undo stack** — after accepting a diff, Ctrl+Z undoes the entire AI edit as a single operation (not character by character). Conceptually: the AI replacement is one undo entry.
- [ ] **Persist prompt history across sessions** — currently session-only. Save the last N prompts to disk so they survive restarts. Developers repeat patterns ("update the spec for X", "add error handling") and history is muscle memory.
- [ ] **Prompt context: clipboard** — add a `@clipboard` token in the Ctrl+K prompt that expands to the current clipboard content. Useful for "rewrite this in the style of @clipboard" or "merge this with @clipboard".
- [ ] **AI: generate from blank** — when Ctrl+K is used on an empty tab with no selection, treat the prompt as a generation instruction rather than an edit. "Write a Python script that..." or "Draft a SPEC for...". The result fills the tab.

---

## Status Bar

A single line at the bottom of the window. Dense, informative, unobtrusive.

- [ ] **Status bar** — show: `Ln {line}, Col {col}` · `{selection count} selected` · `{word count} words` · `{line count} lines` · `UTF-8` · `LF`/`CRLF` · `{language}`. Click on encoding or line ending to change it. Click on Ln/Col to open Go to Line.

---

## Developer Workflow

Features that make Clankpad useful beyond a plain scratchpad — without turning it into an IDE.

- [ ] **Syntax highlighting** — even basic keyword coloring makes code significantly more readable. Detect language from file extension. Start with a small set: Python, JavaScript/TypeScript, Dart, Rust, Go, C/C++, JSON, YAML, Markdown, SQL, HTML/CSS. Use a tree-sitter grammar or a simpler regex-based highlighter. This is the single biggest upgrade for a developer-facing editor.
- [ ] **Minimap** — a narrow column on the right showing a zoomed-out view of the file. Click to navigate. Useful for orientation in longer files.
- [ ] **Sticky scroll / breadcrumb** — show the current function/class/section name at the top of the editor when scrolled deep into a file. Requires parsing; could start with indent-based heuristics.
- [ ] **Diff two tabs** — select two open tabs and see a side-by-side diff. Useful for comparing AI output variations, before/after edits, or two versions of a spec.
- [ ] **Markdown preview** — side-by-side or toggle for `.md` files. Clankpad is already used for specs and READMEs; rendering them is natural.
- [ ] **Open containing folder** — right-click tab → "Reveal in Explorer". One click to get to the file's directory.
- [ ] **Copy file path** — right-click tab → "Copy Path" / "Copy Relative Path". Useful for pasting into terminal commands or AI prompts.
- [ ] **Encoding handling** — detect file encoding on open (UTF-8, UTF-16, Latin-1). Show in status bar. Allow conversion on save.
- [ ] **Line ending handling** — detect and preserve CRLF vs LF. Show in status bar. Allow conversion.
- [ ] **Trim trailing whitespace on save** — optional setting. Common hygiene for code files.

---

## System Integration

Making Clankpad a first-class citizen on the desktop.

- [ ] **Command palette (`Ctrl+Shift+P`)** — searchable list of all commands. The universal escape hatch when you can't remember a shortcut. Every action in the app should be palette-accessible.
- [ ] **Drag and drop files** — drop a file onto the window to open it. Drop onto a specific tab position to insert it there.
- [ ] **File watcher** — detect when an open file is modified externally (by an AI agent, build tool, git, etc.). Show a notification: "File changed on disk. Reload?" with options to reload or keep the editor version. Critical when AI agents are writing to the same files.
- [ ] **CLI arguments** — `clankpad file.txt` opens the file in a new tab. `clankpad .` opens all files in the directory. Support piping: `cat log.txt | clankpad` opens stdin in a new tab. Makes Clankpad usable from terminal workflows.
- [ ] **Always-on-top mode** — toggle to pin the window above all others. Useful as a persistent scratchpad while working in an IDE or terminal. Shortcut: `Ctrl+Shift+A` or similar.
- [ ] **Remember window position and size** — persist window geometry in the session file. Restore on launch.
- [ ] **Single-instance mode** — opening a file when Clankpad is already running sends it to the existing instance instead of launching a second window. Prevents session conflicts.
- [ ] **File associations** — register Clankpad as a handler for `.txt`, `.md`, etc. in the Windows registry. "Open with Clankpad" in the right-click menu.

---

## Quality of Life

Small things that compound.

- [ ] **Font size adjustment (`Ctrl+=` / `Ctrl+-`)** — zoom in and out. Persist the setting. `Ctrl+0` resets to default.
- [ ] **Light / dark / system theme** — already planned in SPEC Phase 4. Follow system preference by default, with manual override.
- [ ] **Auto-save to disk** — optional: automatically write dirty file-backed tabs to disk after N seconds of inactivity. Separate from session persistence. Off by default (some people don't want silent writes), but invaluable when enabled.
- [ ] **Window title** — show the active file name and path in the title bar. Already planned in SPEC Phase 4. `filename.txt — Clankpad` or `● filename.txt — Clankpad` when dirty.
- [ ] **Zen mode (`F11` or `Ctrl+Shift+F`)** — full-screen with no tab bar, no status bar. Just the text. For focused writing. Escape or same shortcut to exit.
- [ ] **Distraction-free centering** — in zen mode, constrain the text column to ~80 characters centered in the window. Reduces eye travel on wide monitors.
- [ ] **Open file type filter memory** — remember the last file type filter used in the open/save dialogs. If you're always opening `.md` files, don't make you scroll past `*.*` every time.
- [ ] **Custom font selection** — let users pick their preferred monospace font (Fira Code, JetBrains Mono, etc.). Persist in settings.

---

## Settings

A lightweight settings system to back the features above.

- [ ] **Settings file** — `%APPDATA%\Clankpad\settings.json`. Separate from `session.json` (settings are preferences; session is state). Editable as a JSON file directly — no settings UI needed initially. Clankpad can open its own settings file in a tab for editing.
- [ ] **Settings candidates**: font family, font size, tab size (2/4/8), word wrap default, auto-save interval, theme, line numbers on/off, always-on-top, trim trailing whitespace, prompt templates list.

---

## Priority Suggestions

If building these incrementally, this order maximizes impact for the target audience (developer using AI coding agents):

1. **Status bar** (Ln/Col, word count) — near-zero effort, immediately useful
2. **Find and replace** — the find bar is already built; adding replace is incremental
3. **Line numbers** — high-signal, low-effort; makes the editor feel real
4. **Command palette** — becomes the backbone for discoverability as features grow
5. **File watcher** — critical when AI agents modify files externally
6. **Syntax highlighting** — the single biggest visual upgrade
7. **Reopen closed tab** — saves users from accidental data loss frustration
8. **Tab switching (`Ctrl+Tab`)** — expected muscle memory from every other tabbed app
9. **Prompt templates** — reduces Ctrl+K friction for repeated patterns
10. **Copy as markdown code block** — bridges Clankpad to the AI agent workflow
