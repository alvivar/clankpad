# Clankpad Code Review

Scope: `SPEC.md` and current implementation in `lib/`.
Focus: simplicity first, then performance, Flutter best practices, and organization.

---

## Overall assessment

The project is in good shape: the architecture is intentionally small, state boundaries are clear (`TextEditingController` vs `ValueNotifier<bool>` vs `ChangeNotifier`), and most of the SPEC is implemented cleanly without unnecessary abstractions.

Direct answer on quality: **good overall (~8/10)**. `flutter analyze` is clean, and there is no major overengineering.

It is **not** perfect yet: there are a few rough/"ugly" spots (mainly around AI flow correctness and `EditorScreen` size) worth fixing.

If you want to keep things simple and reliable, I’d keep the current structure and only address a few targeted issues below.

---

## High-priority findings

### 1) AI diff can be applied to the wrong tab (correctness)

**Where**

- Snapshot is taken from the active tab: `lib/screens/editor_screen.dart:229-238`
- Accept applies to _current_ active tab: `lib/screens/editor_screen.dart:428-446`
- Tab switching/new/close is still available from tab bar and root actions:
    - `lib/screens/editor_screen.dart:580-593`
    - `lib/screens/editor_screen.dart:611-616`

**Why this matters**
If the user switches tabs (mouse) or triggers tab/file actions while AI is running, the snapshot and the apply target can diverge. That risks writing AI output into a different tab than the one that was snapshotted.

**Simple fix (recommended)**

- While `_aiPromptVisible || _editorReadOnly || _diffVisible`, disable structural actions (new/close/open/switch).
- Also capture a `snapshotTabId` and apply/reject against that tab ID instead of `activeTab` as a safety net.

No new abstractions needed—just guards + one stored ID.

---

### 2) Empty AI output currently produces no diff UI

**Where**

- Diff opens only on first chunk: `lib/screens/editor_screen.dart:365-386`

**Why this matters**
If Pi returns an empty transformation (valid for “delete this”), no `text_delta` may arrive. The stream ends and the user sees no diff and no explicit result state.

**Simple fix (recommended)**
After streaming completes, if `!diffOpened`, open the diff with `proposed = ''` (or explicitly treat as no-op with a banner). This preserves deterministic UX.

---

## Medium-priority findings

### 3) Debounced session writes are synchronous on the UI isolate (jank risk)

**Where**

- Timer triggers sync write: `lib/services/session_service.dart:64-77`
- Sync flush on exit is fine: `lib/services/session_service.dart:89-92`

**Why this matters**
For large documents/tabs, `jsonEncode + writeAsStringSync + renameSync` every debounce window can cause visible typing hitches.

**Simple fix (recommended)**

- Keep `flushSync()` exactly as-is for exit correctness.
- Make the debounced `_write` path async (`writeAsString`/`rename`) and fire-and-forget from timer callback.

This keeps behavior the same while improving responsiveness.

---

### 4) `_openAiPrompt` async flow is harder to read than needed

**Where**

- Nested `.then(...).then(...).catchError(...)`: `lib/screens/editor_screen.dart:246-304`

**Why this matters**
The logic is correct, but readability/maintainability is lower than an `async/await` + `try/catch` equivalent.

**Simple fix (optional)**
Move this block into a small private async method (e.g., `_loadModelsIfNeeded()`), same behavior, fewer nesting levels.

---

### 5) File-open tab reuse rule should be explicit about “clean”

**Where**

- `reuseActive` currently checks only filePath + empty text: `lib/state/editor_state.dart:145-146`

**Why this matters**
SPEC says “empty and clean”. In practice current logic usually works, but explicitly checking `!active.isDirty` makes intent clearer and future-proof.

**Simple fix (optional)**

```dart
final reuseActive = active.filePath == null &&
    active.controller.text.isEmpty &&
    !active.isDirty;
```

---

## Low-priority quality findings

### 6) `EditorScreen` is getting too large (organization/readability)

**Where**

- `lib/screens/editor_screen.dart` (single class handling tabs, file I/O, dialogs, AI prompt flow, streaming diff, model loading, history, focus)

**Why this matters**
As features grow, this file becomes harder to scan and reason about. It is still manageable, but this is the main readability hotspot.

**Simple fix (optional)**
Keep the same architecture, but split into a few private helper methods grouped by concern (file actions / AI actions / dialog helpers), and optionally move one small UI chunk (error banner or loading row) into a private widget in the same file.

---

### 7) Root-shortcut blocker maps are duplicated in two overlays (minor noise)

**Where**

- `lib/widgets/ai_prompt_popup.dart`
- `lib/widgets/ai_diff_view.dart`

**Why this matters**
Not a bug, but duplicated key maps can drift over time when shortcuts are added/removed.

**Simple fix (optional)**
If this list changes again, centralize the blocker map into one shared `const` and reuse it in both widgets. If you prefer fewer files, keeping duplication is acceptable for now.

---

## What is already strong (keep as-is)

- Minimal dependency footprint (`file_selector` only)
- Clear reactive split in `EditorState` (good Flutter practice)
- Focus management is deliberate and well-documented
- Session restore edge cases are thoughtfully handled
- Pi RPC integration avoids overengineering while still covering failures

---

## Suggested order of changes

1. Fix AI tab-target correctness + lock structural actions during AI states.
2. Handle empty AI output deterministically.
3. Make debounced session writes async (keep sync exit flush).
4. Optional readability polish (`_openAiPrompt`, explicit clean check in reuse rule).
5. Optional organization cleanup in `EditorScreen`; optionally deduplicate overlay shortcut-blocker maps.

That should improve reliability/performance without adding architectural complexity.
