# Clankpad — Application Review

**Reviewed:** 2026-05-15 (supersedes previous review of same date)
**Scope:** `lib/`, `pubspec.yaml`, `analysis_options.yaml`, `SPEC.md`, platform runners
**Tooling state:** `flutter analyze` passes with no issues; no test suite
**Priority guidance:** simplicity first, performance second, then idiomatic Dart/Flutter. Every line justified. Abstractions only when essential.

---

## Executive summary

Clankpad is a **good, intentionally simple Flutter desktop app**. Since the previous review the codebase has gained a second AI backend (Claude Code), per-provider preference persistence, a fixed Pi command-sequencing race, and a shared system prompt. None of these additions introduced new architecture overhead — the provider abstraction stayed small and the dependency surface unchanged.

The strongest parts of the codebase remain:

- very small dependency surface (`file_selector` only)
- sensible flat structure (`models/ state/ services/ screens/ widgets/`)
- typing performance protected by a deliberate state split
- careful desktop focus/keyboard discipline
- minimal abstraction around AI providers

Four **verified real bugs** have appeared in the post-review code surface and should be fixed before further feature work. A small set of structural items from the previous review are still valid and worth doing. Several other items from that previous review have been intentionally dropped under the project's philosophy — see "Scope notes" below.

---

## Tier 1 — Real bugs to fix first

These are user-visible defects verified against current source. All four are small, localized changes.

### B1. AI preferences silently fail to persist

**Files:** `lib/screens/editor_screen.dart` (around `_submitAiPrompt`), `lib/state/editor_state.dart`

`_submitAiPrompt()` writes provider/model/thinking-level choices directly to `_state.lastProviderKey` and `_state.providerPrefs[...]`. The inline comment claims "the debounced session save picks them up automatically" — this is **wrong**. Session writes are only scheduled by `EditorState.onAnyChange`, which is fired only from text edits and structural changes. Updating provider prefs alone does not fire it.

User-visible effect: switch model, run AI edit, reject diff, close app → choices lost. In practice this often "works" because users also type, which triggers `onAnyChange` for unrelated reasons.

**Fix shape:** add `EditorState.setAiPrefs({providerKey, modelProvider, modelId, thinkingLevel})` that mutates both fields and calls `onAnyChange?.call()`. Replace the two direct field writes in `_submitAiPrompt` with this one call. Remove the misleading comment.

### B2. Pi concurrent-startup race spawns duplicate processes

**File:** `lib/services/pi_provider.dart` (`_ensureRunning`)

```dart
if (_process != null) return;
proc = await Process.start(...);
_process = proc;
```

If two callers reach `_ensureRunning()` concurrently (plausible: popup open kicks off `fetchModels()`, user submits before it returns), both pass the null check, both spawn a Pi process, the first one is orphaned (`_process` is overwritten and the original is never killed). The first caller's `await` then returns into a state where `_process` is not the process they spawned.

**Fix shape:** extract the current spawn body of `_ensureRunning` into a private `_spawn()` and cache the in-flight startup as a future:

```dart
Future<void>? _starting;

Future<void> _ensureRunning() {
  if (_process != null) return Future.value();
  return _starting ??= _spawn().whenComplete(() => _starting = null);
}
```

### B3. Claude Code accepts partial output as completion

**Files:** `lib/services/claude_code_provider.dart` (around line 167), `lib/screens/editor_screen.dart` (`_submitAiPrompt` error handler around line 783)

```dart
if (exitCode != 0 && !anyOutput) { throw ...; }
```

If Claude Code emits text deltas then crashes with non-zero exit, the diff view shows partial text with no error indication. **Worse:** the diff opens on the first text chunk (`_diffVisible = true` at `editor_screen.dart:745`), and when the provider then throws, the error banner is shown but the diff *stays visible and remains accept-able* (the `finally` block only resets `_editorReadOnly` when `!_diffVisible`). The user is likely to Accept the partial diff and corrupt their document.

This is the worst-shaped failure mode in the app: silent partial corruption disguised as success.

**Fix shape (two parts, both required):**

1. In `ClaudeCodeProvider.streamEdit`: treat any non-zero exit as a hard error (`throw AiProviderError(...)`), regardless of whether output was emitted. The current `&& !anyOutput` guard is the bug.
2. In `EditorScreen._submitAiPrompt` error handler: when a provider error happens after the diff has opened, **auto-reject the diff** (close it, clear the edit-target highlight, unlock the editor). The document itself is not modified until Accept, so no rollback is needed — the goal is simply to prevent the user from accidentally accepting an incomplete diff. Surfacing `lastWarning` alone is not sufficient: once a diff is on screen, a single Enter accepts it.

### B4. `exit(0)` shutdown path orphans warm Pi subprocess

**Files:** `lib/main.dart` (`_exitApplication`), `lib/screens/editor_screen.dart` (`onExitRequested` callsite)

Two close paths exist:

- **OS-initiated close** (X button, Alt+F4) → `AppLifecycleListener.onExitRequested` returns `AppExitResponse.exit` → Flutter's normal shutdown runs, which *should* eventually call `EditorScreen.dispose()` and iterate `_providers`. **Believed correct but not manually verified end-to-end** (Flutter does not guarantee a synchronous dispose chain on every platform; worth confirming with Task Manager on Windows release builds).
- **App-initiated close** (last tab closed) → `widget.onExitRequested()` → `_exitApplication` → `flushSync()` + `exit(0)`. **No dispose chain.** On Windows, Dart child processes are not in a job object with the parent, so the warm Pi (Node) process survives.

The `exit(0)` itself is intentional and correct — it works around a release-build slow-close caused by the platform channel during normal shutdown. But cleanup needs to happen *before* it on the app-initiated path. Whether the OS-initiated path needs an explicit pre-dispose hook is open and requires the Task Manager verification above; if `dispose()` does in fact run reliably during Flutter's normal shutdown, that path needs no change.

**Fix shape:** EditorScreen should kill its providers before invoking `onExitRequested`, e.g.

```dart
Future<void> _exitNow() async {
  for (final p in _providers.values) {
    await p.dispose();
  }
  await widget.onExitRequested();
}
```

and call `_exitNow()` instead of `widget.onExitRequested()` at the close site.

---

## Tier 2 — Structural findings

These were the previous review's top items. Status is current.

### S1. `Map<String, dynamic>` for AI model data should become a typed class

**Status:** still valid; worse than before because dual-provider added `_modelCache`, `_fetchResultCache`, and many helpers (`_modelKey`, `_effectiveModelForUi`) that exist to compensate for the missing type.

**Files:** `ai_provider.dart`, `pi_provider.dart`, `claude_code_provider.dart`, `editor_screen.dart`, `ai_prompt_popup.dart`.

A typed model is **simpler** than a map here: it removes string-key lookups, casts, the `_modelKey` helper, and accidental typos. Recommended shape:

```dart
class AiModel {
  final String provider;
  final String id;
  final String name;
  final bool supportsReasoning;
  const AiModel({required this.provider, required this.id, required this.name, this.supportsReasoning = false});
}
```

Then replace `List<Map<String, dynamic>>` with `List<AiModel>` throughout. This is the single highest-leverage cleanup.

### S2. Make debounced session writes async

**Status:** still valid.
**File:** `lib/services/session_service.dart`

The debounced `_write()` path uses `writeAsStringSync` + `renameSync` on the UI isolate. `flushSync()` is correctly synchronous for app exit, but the every-500-ms case during heavy typing should not block frames.

Keep `flushSync()` as-is. Make `_write()` `Future<void>` and use `writeAsString` + `rename` (both already exist as async on `File`). Errors stay swallowed and logged.

### S3. Share blocked-shortcut maps between AI popup and diff view

**Status:** still valid; **worse**. The two maps have drifted — `AiDiffView` is missing at least `Ctrl+F` and `Ctrl+Tab` which `AiPromptPopup` blocks.

**Files:** `lib/widgets/ai_prompt_popup.dart`, `lib/widgets/ai_diff_view.dart`.

Extract a shared `const` `Map<ShortcutActivator, Intent>` in `lib/models/intents.dart` (or alongside it). Use it from both widgets. Comment that any new app-level shortcut must be added here to be blocked while AI overlays are active.

### S4. Replace `.then()` / `.catchError()` with `async` / `await`

**Status:** still valid.
**File:** `lib/screens/editor_screen.dart` (`_fetchModelsForActiveProvider`)

The rest of the screen is `async`/`await`. One chained-future site is a readability outlier.

### S5. Session restore is fragile against malformed-but-parseable `session.json`

**Status:** newly identified.
**File:** `lib/state/editor_state.dart` (`restoreFromSession`, `_restoreTab`), `lib/main.dart`

`SessionService.readSession()` catches JSON-parse errors and returns null — good, a corrupt file does not prevent startup. But once the JSON parses, `restoreFromSession()` performs unchecked casts: `prefsJson.map((k, v) => MapEntry(k, Map<String, String>.from(v as Map)))`, `raw as Map<String, dynamic>`, `(json['nextTabId'] as int?)`, etc. If `session.json` is parseable but malformed at the outer shape level (`providerPrefs: 42`, `tabs: "oops"`, `tabs: [42]`), restore throws and the unhandled exception in `main.dart` prevents the app from starting at all. (Individual tab entries with missing keys are handled — `_restoreTab` defaults most fields — so the realistic failure mode is type mismatches at the outer level, not missing keys.)

This breaks the implicit contract that a corrupt session file should never block startup.

**Fix shape:** either wrap the `restoreFromSession` call in `main.dart` with a `try/catch` that falls back to a fresh empty state and surfaces a startup notice, or harden each cast inside `restoreFromSession` with `is`-checks and skip-and-notice on mismatch. The first is simpler and matches the project's "swallow and log" stance for session errors.

---

## Tier 3 — Nits

### N1. `_spaces()` in `editor_area.dart` is non-idiomatic

`List.filled(count, ' ').join()` → `' ' * count`. Trivial.

### N2. `UnmodifiableListView(_tabs)` re-wraps on every access

Acceptable — the code comment already documents this as an intentional O(1) wrapper. The previous review flagged this; I would now demote it to "do not touch".

### N3. Search recomputes matches on every keystroke

Acceptable at current scale. If it becomes visible on very large files, debounce the **search input only**, not editor input.

### N4. `pubspec.yaml` description is still `"A new Flutter project."`

Trivial fix, but real signal of unfinished polish.

---

## Documentation drift (separate from code review)

### D1. SPEC.md §3.2 documents the old session schema

SPEC.md still describes `lastModelProvider` / `lastModelId` / `lastThinkingLevel` as the AI persistence fields. The code uses `lastProviderKey` + per-provider `providerPrefs` (see `editor_state.dart` and `session_service.dart`). The spec needs to catch up.

### D2. SPEC.md references the old `PiRpcService` class

SPEC.md still references `pi_rpc_service.dart` / `PiRpcService` (visible around lines 977, 1073–1077, 1188, 1198–1208). The code has since renamed and restructured this as `pi_provider.dart` / `PiProvider` (implementing the `AiProvider` interface). Either update the SPEC to current names or move the legacy text into a clearly-marked "history" appendix.

### D3. SPEC.md documents an unimplemented markdown-preview feature

SPEC.md describes a markdown-preview feature (§2.9, shortcut tables, dependency list) in detail, but the feature does not exist in the code: `pubspec.yaml` has no `flutter_markdown_plus` dependency, no preview widgets exist, no `_markdownPreview` state field. Either roll the SPEC additions back or ship the feature.

---

## Things to preserve

These should be kept as they are during refactors:

1. **No rebuilds on every keystroke.** The split between `notifyListeners()` for structural changes and per-tab `ValueNotifier<bool>` for dirty state is correct for an editor and should not be replaced with a generic state-management framework.
2. **Minimal dependency footprint.** `file_selector` is the only non-Flutter dep. Adding markdown rendering will add one more; resist anything else.
3. **Provider abstraction size.** `AiProvider` is small and sufficient. The recent `systemPrompt` static const fits this style — a shared input, not an abstraction layer. Do not turn it into a richer hierarchy.
4. **Focused widget extraction.** `FindBar`, `EditorArea`, `EditorTabBar`, `AiDiffView`, `AiPromptPopup` are good boundaries.
5. **Desktop focus restoration discipline.** One of the app's quality markers — don't lose it during the `EditorScreen` split (S3).
6. **Reliable release-build close.** The current `flushSync()` + `exit(0)` path solves a real platform-channel hang. Preserve the *outcome* (fast, deterministic close that saves session). The implementation may need to change to also dispose providers (B4) — that is OK as long as close stays reliable.
7. **Pi command sequencing via id-tagged `sendCommand`.** Recently fixed; the race against Pi's concurrent JSONL dispatcher is real and the fix is correct. Do not "simplify" back to fire-and-forget.
8. **Shared system prompt + per-request `IMPORTANT:` lines.** `AiProvider.systemPrompt` is passed to both backends via `--system-prompt`; per-request prompts in `buildPromptMessage` still include `IMPORTANT:` constraints. This belt-and-suspenders structure is deliberate — keep both.
9. **Atomic session writes.** The write-to-`.tmp`-then-rename pattern in `SessionService._write()` makes session.json crash-safe on NTFS. Preserve this even when converting to async (S2) — async `writeAsString` + `rename` keep the same semantics.

---

## Suggested order of work

### Tier 1 — bugs (do first; all small)

Ordered by user-visible damage potential, worst first:

1. **B3 — Claude Code partial-output handling.** Document corruption risk; do this first.
2. **B1 — AI prefs persistence** (`EditorState.setAiPrefs`). Lost user preferences.
3. **B4 — provider disposal before `exit(0)`.** Orphan processes; also covers the OS-close uncertainty.
4. **B2 — Pi concurrent-startup race.** Wasted resources, no data loss.

### Tier 2 — structural (each independently valuable; do in any order)

5. S3 — share blocked-shortcut maps (one-file change; closes drift risk).
6. S1 — typed `AiModel` (highest cleanup leverage; net code reduction).
7. S2 — async session writes.
8. S4 — replace `.then/.catchError`.
9. S5 — harden `restoreFromSession` against malformed-but-parseable JSON.

### Tier 3 — nits and docs (do anytime)

10. N1, N4
11. D1, D2, D3

---

## Scope notes

This review intentionally omits items the project owner explicitly chose to skip under the project's stated philosophy ("simple, performant, readable, idiomatic; every line justified; abstractions only when essential"):

- **Splitting `EditorScreen`** — a 1195-line single file with clean sections and justified content is acceptable; splitting it would trade scrolling for navigation and is not essential.
- **Formalizing `onAnyChange`** — the raw `VoidCallback?` field has one owner and a documented contract; replacing it with a setter + assert is ceremony, not correctness. The B1 fix already adds `setAiPrefs(...)`, which is the only place where the implicit contract had bitten us.
- **`EditorTab.markSaved` helper** — audit shows the savedContent/isDirty invariant is currently upheld at every callsite (3 sites, all correct). Wrapping 2 lines in a method is preference, not essential abstraction.
- **Test suite** — deferred until concrete bugs make tests worth their cost. If `pi_provider.dart` starts producing reproducible regressions, revisit then.

These omissions are deliberate. Do not re-add them in a future review unless concrete evidence (a regression, a bug, a real readability blocker) makes the case.

## Final verdict

The codebase is still in **good shape**. The new bugs are typical "second feature pushed past first review" mistakes (prefs persistence, concurrent startup) and are cheap to fix.

The single biggest cost-of-not-fixing item is **B3** (Claude Code silently accepting partial output), because it can corrupt user documents. The single biggest cleanup-leverage item is **S1** (typed AI model) — it actually *reduces* code by replacing ad-hoc helpers with a 4-field struct.

If only one tier gets done, do Tier 1.
