# Shutdown Refactor — Reliable Child-Process Cleanup

Plan to fix how Clankpad terminates its AI child processes (Pi, Claude Code)
on app exit. Reviewed with gpt@clankpad.

## Problem

Three defects in the current shutdown handling:

- **A — Leak on window close.** Clicking the window X / Alt+F4 routes to
  `main.dart`'s `AppLifecycleListener.onExitRequested`, which flushes the
  session and returns `exit` but **never disposes the providers**. The most
  common close path leaks the warm Pi process. Only the close-last-tab path
  (`_handleCloseTab`) disposes providers.

- **B — Windows process tree orphan.** Pi is spawned with `runInShell: true`
  (required: the npm global install is `pi.cmd`, not `pi.exe`). The real tree
  is `clankpad.exe → cmd.exe (/c pi.cmd) → node`. `proc.kill()` calls
  `TerminateProcess` on the **cmd.exe handle only** — Windows does not cascade
  to children, so the actual `node` Pi survives **even on the path that does
  call dispose**. Claude Code shares the same `runInShell` + `kill()` pattern.

- **C — Duplicated cleanup.** Provider disposal lives in both `_handleCloseTab`
  (manual loop) and `EditorScreen.dispose`, and `exit(0)` is what forces the
  manual copy. The two close paths never share a route.

## Goal

Both close paths (window-X and close-last-tab) converge on a single OS exit
request. Each owner cleans up its own resource exactly once, idempotently, and
the whole Pi/Claude process **tree** is killed on Windows.

## Design

Funnel every exit through `ServicesBinding.instance.exitApplication(
AppExitType.cancelable)`. That runs **all** registered
`AppLifecycleListener.onExitRequested` handlers (awaited, no early-return),
then the platform terminates the app. Each component registers its own
handler:

- `main.dart` (`ClankpadApp`) → flush session.
- `EditorScreen` → dispose providers (kills the Pi/Claude tree).

`exitApplication` is preferred over `dart:io`'s `exit(0)` (Flutter's own
guidance), and replacing the manual provider loop with it removes the
duplication in C.

## Changes

### 1. New shared helper — `lib/services/process_utils.dart`

The tree-kill logic is subtle (taskkill + fallback) and needed by **both**
providers, so it lives in one place rather than being copy-pasted.

```dart
import 'dart:io';

/// Kills [proc] and, on Windows, its entire child tree.
///
/// `runInShell: true` spawns `cmd.exe → <cli>.cmd → node`; `proc.kill()` would
/// terminate only the cmd.exe wrapper and orphan the real CLI process.
/// `taskkill /T` takes the descendants too. Best-effort and non-throwing:
/// falls back to `proc.kill()` if taskkill is missing or the process is
/// already gone.
Future<void> killProcessTree(Process proc) async {
  if (Platform.isWindows) {
    try {
      final r = await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      if (r.exitCode != 0) proc.kill();
    } catch (_) {
      proc.kill();
    }
  } else {
    proc.kill();
  }
}
```

### 2. `PiProvider._killProcess` — use the helper

Replace `proc.kill();` with `await killProcessTree(proc);`. The rest
(cancel stdout subscription, best-effort `stdin.close()`) is unchanged.

### 3. `ClaudeCodeProvider` — use the helper

`abort()` and `dispose()` currently call `_activeProcess?.kill()`. Route both
through `killProcessTree`. Claude is one-shot, but an in-flight request aborted
mid-stream has the same orphan risk. `abort()` stays best-effort
(fire-and-forget the future); `dispose()` awaits it.

### 4. `EditorScreen` — own provider cleanup via its own lifecycle listener

- Add `late final AppLifecycleListener _lifecycleListener;` created in
  `initState`:

  ```dart
  _lifecycleListener = AppLifecycleListener(
    onExitRequested: () async {
      await _disposeProviders();
      return AppExitResponse.exit;
    },
  );
  ```

- Add an idempotent, non-throwing disposal method (memoised so a graceful exit
  that calls `onExitRequested` and later `dispose` cannot double-dispose):

  ```dart
  Future<void>? _disposeProvidersFuture;

  Future<void> _disposeProviders() {
    return _disposeProvidersFuture ??= () async {
      for (final p in _providers.values) {
        try {
          await p.dispose();
        } catch (_) {}
      }
    }();
  }
  ```

- `dispose()`: add `_lifecycleListener.dispose();` and replace the existing
  provider loop with `_disposeProviders();` (best-effort, covers the non-exit
  teardown case). Provider `dispose` is already idempotent (`_killProcess`
  guards on null); the memo guards against the double call.

### 5. `EditorScreen._handleCloseTab` — request OS exit, drop manual cleanup

In the `_shouldExitOnCloseTab` branch, replace:

```dart
for (final p in _providers.values) { await p.dispose(); }
await widget.onExitRequested();
```

with:

```dart
await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
```

`_shouldExitOnCloseTab` stays — it still decides _whether_ to exit.

### 6. `main.dart` — delete the `exit(0)` path

- Delete `_exitApplication` and the `onExitRequested` argument threaded into
  `EditorScreen`.
- Keep `ClankpadApp`'s `AppLifecycleListener` (flush session) — it now fires on
  both window-X and the `exitApplication` call from close-last-tab.
- Remove the `dart:io` import if `exit(0)` was its only use.

### 7. `EditorScreen` constructor — drop `onExitRequested`

Remove the now-unused `onExitRequested` field/param.

## Invariants & edge cases

- **Both handlers return `exit`.** `handleRequestAppExit` cancels the exit if
  _any_ observer returns `cancel`. No current handler does. If a future
  handler needs to cancel (e.g. an unsaved-changes guard), it must be added
  deliberately — document this so the convergence isn't broken by accident.
- **Handlers must not throw.** A throw from `onExitRequested` can disrupt exit
  handling; `_disposeProviders` swallows per-provider errors.
- **Dirty tabs:** `_handleCloseTab` resolves the dirty-save dialog _before_
  deciding to exit, so `exitApplication` is only called once state is settled.
  Window-X does **not** prompt for unsaved changes (existing behaviour — the
  session auto-persists and restores). Unchanged by this refactor.
- **Mid-stream close:** if an edit is streaming when the app exits,
  `PiProvider.dispose` completes pending commands with an error and kills the
  tree; the streaming future may throw `AiProviderError`, but the app is
  already terminating. Acceptable.

## Smoke test (manual, Windows)

Use Task Manager to confirm no orphaned `node` / `pi` / `claude` process after
each:

1. Open app → trigger one Pi edit (spawns warm Pi) → close via **window X**.
   → Pi gone.
2. Open app → trigger one Pi edit → **close the last tab**. → Pi gone, app exits.
3. Open app → start a Pi edit → **close window mid-stream**. → Pi gone, clean exit.
4. Repeat 1–2 with Claude Code as the provider.
5. Normal multi-tab close (not last) → app stays open, no exit.

## Acceptance criteria

- `flutter analyze` clean.
- No orphaned child process in any smoke-test scenario.
- Provider disposal exists in exactly one logical place per trigger
  (lifecycle for exit, `dispose` for teardown), sharing one memoised method.
- No `exit(0)`, no `_exitApplication`, no `onExitRequested` threading, no
  manual provider loop in `_handleCloseTab` left behind.

## Out of scope

- Job-object based child management (heavier than needed here).
- Prompting for unsaved changes on window-X (separate behaviour decision).
- Any change to the streaming/edit flow itself.
