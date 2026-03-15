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

These are defensive safety nets. They are probably unnecessary under the current UI rules, but they do provide protection if the flow changes later.

### 8. Remove AI snapshot tab safety-net

- **File:** `lib/screens/editor_screen.dart`
- **Remove / simplify:**
  - `_snapshotTabId`
  - `_snapshotTab`
  - fallback logic that tries to find the snapshotted tab later
- **Why:** while AI is active, the app blocks tab switching, tab closing, opening files, and creating tabs. Under current behavior, the active tab should not change.
- **Risk:** medium
- **Recommendation:** only remove this after confirming all AI-active guards are intentional and permanent.

### Validation for Batch 4

- start AI prompt
- cancel during loading
- accept diff
- reject diff
- verify edits always apply to the expected tab

---

## Batch 5 — Project/file cleanup based on product scope

These are not code-level dead branches; they are project-level removals if the app scope is narrower.

### 9. Remove empty Apple test stubs

- **Files:**
  - `ios/RunnerTests/RunnerTests.swift`
  - `macos/RunnerTests/RunnerTests.swift`
- **Why:** they are template tests with no assertions and no useful coverage.
- **Risk:** low, but removing them also requires cleaning up Xcode project references / test targets.

### 10. Remove mobile platform folders if the app is desktop-only

- **Folders:**
  - `android/`
  - `ios/`
- **Why:** README and SPEC position the app primarily as a Windows desktop app. If mobile is not a real target, these are maintenance overhead.
- **Risk:** high from a project-scope perspective, low technically
- **Only remove if:** you are intentionally committing to desktop-only support.

### Validation for Batch 5

- confirm supported target platforms in README / SPEC
- run builds only for intended targets
- verify CI / release scripts do not depend on removed targets

---

## Recommended execution order

1. **Batch 1** — easy wins, almost no behavior risk
2. **Batch 2** — simplify unused flexibility in the popup API
3. **Batch 3** — remove legacy compatibility if acceptable
4. **Batch 4** — remove defensive safety nets only if you want stricter code
5. **Batch 5** — project-scope cleanup

---

## Suggested stop points

If you want conservative cleanup:

- do **Batch 1 + Batch 2** only

If you want pragmatic cleanup and do not care about old sessions:

- do **Batch 1 + Batch 2 + Batch 3**

If you want aggressive cleanup:

- do **all batches**, but confirm platform scope first

---

## Summary

### Best low-risk removals

- dead `_lastWarning` state in Claude provider
- redundant `_diffVisible` check in `_aiActive`
- no-op restore-time `notifyListeners()`
- nullable / optional popup API branches that are never used

### Conditional removals

- legacy session migration
- model-id-only fallback
- AI snapshot tab safety-net

### Project-level removals

- empty iOS/macOS test stubs
- mobile platform folders, if desktop-only is the confirmed scope
