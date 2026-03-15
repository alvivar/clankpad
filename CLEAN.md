# Clankpad cleanup plan

Goal: remove code and files that are currently useless, redundant, or only kept for backward-compatibility / future flexibility.

This is organized into cleanup batches from safest to riskiest.

---

## Batch 1 — Safe, low-risk code deletions

**Status:** done

These should be removable without changing app behavior.

### 1. Remove dead warning state from Claude Code provider

- **Status:** done
- **File:** `lib/services/claude_code_provider.dart`
- **Removed:**
  - `String? _lastWarning;`
  - `_lastWarning = null;`
- **Kept / replaced with:**
  - `@override String? get lastWarning => null;`
- **Why:** `_lastWarning` is never set to a non-null value in this provider, so the field stores no meaningful state.

### 2. Simplify `_aiActive`

- **Status:** done
- **File:** `lib/screens/editor_screen.dart`
- **Changed from:**
  - `bool get _aiActive => _aiPromptVisible || _editorReadOnly || _diffVisible;`
- **Changed to:**
  - `bool get _aiActive => _aiPromptVisible || _editorReadOnly;`
- **Why:** `_diffVisible` is redundant in the current state machine. When the diff is visible, `_editorReadOnly` is already true.

### 3. Remove no-op `notifyListeners()` during restore

- **Status:** done
- **File:** `lib/state/editor_state.dart`
- **Removed:** final `notifyListeners();` inside `restoreFromSession()`
- **Why:** The only current call site is `main()` before `runApp()`, so there are no listeners attached yet.
- **Risk:** low
- **Note:** keep it only if you want `restoreFromSession()` to remain reusable later while listeners may already be attached.

### Validation for Batch 1

- `flutter analyze` ✅
- manual runtime checks still recommended:
  - launch app
  - open/close tabs
  - use Ctrl+K with both providers
  - verify diff + cancel still block tab actions correctly

---

## Batch 2 — Remove unused optional API branches

**Status:** done

These are not dead in the abstract, but they are unused by the current app because there is only one call site and it always passes the data.

### 4. Make AI popup model settings required

- **Status:** done
- **Files:**
  - `lib/widgets/ai_prompt_popup.dart`
  - `lib/screens/editor_screen.dart`
- **Simplified:**
  - `AiModelSettings? modelSettings` → `AiModelSettings modelSettings`
  - model/provider/thinking callbacks are now required
  - removed `settings == null` branches in the popup UI and keyboard handling
- **Why:** `AiPromptPopup` has one call site, and that call site always provides `modelSettings` and the related callbacks.

### 5. Remove unused default for `supportedThinkingLevels`

- **Status:** done
- **File:** `lib/widgets/ai_prompt_popup.dart`
- **Removed:** default value on `supportedThinkingLevels`
- **Why:** the only call site always passes it explicitly.

### Validation for Batch 2

- `flutter analyze` ✅
- manual runtime checks still recommended:
  - open AI popup
  - switch provider
  - change model
  - change thinking level
  - submit prompt

---

## Batch 3 — Remove backward-compatibility code if old session support is no longer needed

**Status:** done

This batch drops support for older persisted session formats.

### 6. Remove legacy session migration fields

- **Status:** done
- **File:** `lib/state/editor_state.dart`
- **Removed migration support for:**
  - `lastModelProvider`
  - `lastModelId`
  - `lastThinkingLevel`
- **Why:** current session writes use `providerPrefs`; these old flat keys were only read for migration.
- **Risk:** medium
- **Effect:** users with very old `session.json` files may lose restored AI model preferences once.

### 7. Remove model-id-only fallback in popup selection logic

- **Status:** done
- **File:** `lib/widgets/ai_prompt_popup.dart`
- **Function:** `_effectiveModelForUi()`
- **Removed:** fallback that matched only by `id` when `selectedProvider` was missing
- **Why:** current app tracks provider + model together; this branch existed only for older state.
- **Risk:** medium

### Validation for Batch 3

- `flutter analyze` ✅
- manual runtime checks still recommended:
  - test with a fresh session
  - optionally delete `%APPDATA%\Clankpad\session.json` first
  - verify provider/model/thinking persistence still works with the new format

---

## Batch 4 — Remove defensive code if you want a stricter, leaner implementation

**Status:** skipped — kept as defensive safety net

### 8. Remove AI snapshot tab safety-net

- **Status:** skipped
- **File:** `lib/screens/editor_screen.dart`
- **Decision:** keep `_snapshotTabId` and `_snapshotTab`. All structural mutations are guarded by `_aiActive` with no gaps, so the safety net is technically redundant. However the code is tiny (~15 lines), has no performance cost, and protects against future mutations that might forget the `_aiActive` guard. Not worth removing.

---

## Batch 5 — Project/file cleanup based on product scope

**Status:** skipped — not worth the churn

### 9. Remove empty Apple test stubs

- **Status:** skipped
- **Files:** `ios/RunnerTests/RunnerTests.swift`, `macos/RunnerTests/RunnerTests.swift`
- **Decision:** removing them requires editing Xcode `.pbxproj` and `.xcscheme` files to clean up test target references. Not worth the fiddly XML surgery for empty test stubs.

### 10. Remove mobile platform folders if the app is desktop-only

- **Status:** skipped
- **Folders:** `android/`, `ios/`
- **Decision:** the app is fundamentally desktop-only, so these are dead weight. However, removing them is a one-way door and the folders cause no runtime or maintenance issues in practice. Can be revisited later if desired (`flutter create . --platforms=android,ios` regenerates them).

---

## Final status

| Batch | Description | Status |
|-------|-------------|--------|
| 1 | Safe low-risk code deletions | ✅ done |
| 2 | Remove unused optional API branches | ✅ done |
| 3 | Remove backward-compatibility code | ✅ done |
| 4 | Remove defensive safety nets | skipped — kept as protection |
| 5 | Project/file cleanup | skipped — not worth the churn |

All changes pass `flutter analyze`.
