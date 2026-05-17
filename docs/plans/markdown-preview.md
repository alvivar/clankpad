# Markdown Preview Plan

## Goal

Add a lightweight Markdown preview mode for Clankpad without turning the app into a full IDE or rich-text editor.

## Status

Wishlist / not implemented.

The archived spec (`docs/archive/SPEC.md`) documented this as if it already existed. It has been extracted here as a plan so the README and current docs only describe shipped behavior.

## User experience

- `Ctrl+M` toggles Markdown preview for the active tab.
- A small eye button in the tab bar toggles the same state.
- Preview mode replaces the editable text area with a read-only rendered Markdown view.
- Switching tabs exits preview mode and returns to editing.
- Opening Find (`Ctrl+F`) exits preview mode so search remains editor-based.
- AI (`Ctrl+K`) blocks preview toggling while popup, streaming, or diff review is active.

## Rendering behavior

- Render a snapshot of the active tab's text at the moment preview is enabled.
- Preview is not live-updated while active.
- Use a scrollable Markdown body with the current app theme.
- Keep links selectable/clickable only if the dependency supports it with minimal code.

## Proposed dependency

Use `flutter_markdown_plus` unless there is a strong reason to choose another package.

Reason: Markdown parsing + widget rendering is too much custom code for this app's scope.

## Implementation outline

1. Add `flutter_markdown_plus` to `pubspec.yaml`.
2. Add a `_markdownPreview` boolean and `_markdownPreviewText` snapshot to `EditorScreen`.
3. Register `Ctrl+M` with a new `ToggleMarkdownPreviewIntent`.
4. Add an eye / eye-off button to `EditorTabBar`.
5. In `EditorScreen`, render either `EditorArea` or a new `MarkdownPreview` widget.
6. Disable editor-only shortcuts while preview is active.
7. Turn preview off on tab switch and when opening Find.
8. Add `Ctrl+M` to AI overlay blocked shortcuts.

## Acceptance checks

- `Ctrl+M` toggles preview for Markdown text.
- The editor is not mounted/editable while preview is active.
- Switching tabs returns to edit mode.
- `Ctrl+F` returns to edit mode and opens Find.
- AI phases block preview toggling.
- Session persistence remains unchanged; preview mode itself does not need to persist.
