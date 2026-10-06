# Code Review

## Status

All eight findings, and the related snapshot-fallback issue, are resolved on `master`. Each fix was a separate task, reviewed independently and committed:

| Finding | Commit | Resolution |
| --- | --- | --- |
| 1. [P1] Pi setup failures could hang | `a1f2c09` | A failed setup or prompt write now ends the request with an error, cleans it up, and allows a retry. |
| 2. [P1] A second AI request could overwrite the first | `8abc3cf` | Only one request runs at a time, until its stream terminates. An abandoned request cannot change the diff, the document or a newer request; a late error from it can still appear in the error banner. |
| 3. [P1] Save completion used a tab index | `1b0f2e9` | A save updates the tab it started from, or nothing if that tab is gone. |
| 4. [P1] Hot exit proceeded after a session-write failure | `ef3e730` | Write failures are shown. A failed final flush keeps the app open. |
| 5. [P2] Search ignored text edits | `52cb74a` | Matches are recomputed on real text changes while Find is open. |
| 6. [P2] Moving lines detached CR from CRLF | `ee870b9` | Line separators and terminal-newline status are preserved. |
| 7. [P2] Model configuration failures changed the selection policy | `f4d4450` | Configuration and loading failures are reported. A filter is never broadened. |
| 8. [P3] Redundant model cache and thinking-level normalization | `b2d5c71` | One cached model result; the private picker trusts its caller's normalization. |
| Related: snapshot-tab fallback | `8abc3cf` | Accept fails explicitly if the original tab is gone. |

## Verification

**Final gates.** These were rerun on the combined tree at `b2d5c71`:
- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: 83 tests passed. The review baseline had 35.

**Per-task checks.**
- Each task added offline tests for the paths it changed: regression tests for R1–R7 and characterization tests for R8. They use fake Pi processes and stdin, held file writes, temporary settings files and widget tests.
- For selected regressions, the implementer showed the test failing with the old behavior temporarily restored. Examples: the R3 save tests, the R4 late-write-after-dispose test, the R5 search tests, the R6 fix-round cases, and the R7 settings-directory case.
- R8 is a behavior-preserving refactor. Its tests pass on the old code and fail on deliberate mutations.
- An independent reviewer checked each diff against the source, its callers and the framework contracts. The reviewer did not rerun the tests.

**Not run.** No GUI session, native window close, real process exit, or live Pi/model request was used for any task. Statements about those paths come from reading the source and from the test seams.

## Decisions and remaining limits

These are deliberate scope decisions, not unresolved parts of the original findings.

- **Pi transport (R1).**
  - There is no abort watchdog.
  - The fake process tests do not guarantee real OS pipe-close ordering or process exit latency.
- **AI requests (R2).** Accepting while generation is still running is retained: the partial result is applied and the request is aborted. No new request can start until the old stream has terminated.
- **Saves (R3).**
  - The fix covers tab identity across one save. It does not schedule concurrent saves of the same tab.
  - The Save As picker is unchanged.
- **Session persistence (R4).**
  - A failed final flush blocks exit, with no discard option and no automatic retry. The next successful write clears the banner.
  - The native close and the successful `exit(0)` path were not run; only the exit callback logic is tested.
- **Search (R5).**
  - Each edit rescans the whole document.
  - The current match index is kept, clamped to the new match count.
  - IME composition was not tested.
- **Moving lines (R6).**
  - `\r\n` and `\n` are separators; a lone `\r` is content, out of scope.
  - Mixed line endings are not normalized: separators inside the moved block travel with it, and the ones around it stay in place.
  - Some moves cannot be represented and are no-ops: from a caret after the final newline, or an empty line moving onto an unterminated last line.
- **Models (R7).**
  - Only Pi's global `~/.pi/agent/settings.json` is read.
  - Supported patterns are a subset of Pi's: case-insensitive `provider/id`, where `*` matches any characters. A missing file, a missing or `null` key, or an empty list means no filter.
  - A loaded model list is required before submitting. To retry after a failure, close the prompt with `Esc`, then press `Ctrl+K`.
  - Unchanged runtime policy: if Pi rejects a model switch, the request still proceeds on Pi's current model and a warning is shown.
- **Model state (R8).** There is no test with an invalid thinking level. Such a level would break an internal guarantee, and Flutter's dropdown would assert.

## Optional manual smoke checks

These are for the user only and not required by the automated gates. They cover native paths that were not run.

Before starting, save or back up real work and use disposable test tabs. Record the original session-directory permissions and Pi `settings.json`, and restore both afterwards.

1. Make the session directory unwritable, edit a tab, and close the window. The app should stay open and show the session-write error.
2. With the directory writable again, close the window. The app should exit, and the tabs should be restored on the next launch.
3. With Pi installed, set `enabledModels` to a pattern that matches nothing. Then start a fresh Clankpad instance and press `Ctrl+K`; an instance that has already loaded the models keeps them and will not reread the setting. The banner should explain the problem. Fix the setting, press `Esc`, then `Ctrl+K`; the models should load.
4. Start an AI edit, cancel it, and immediately press `Ctrl+K`. Ctrl+K should do nothing until the old request has ended, and no old output should appear afterwards.

## Original review (historical)

The review was made at HEAD `a1916da`, before any fixes. Line citations from that review are omitted here because they no longer match the code; the descriptions below are condensed. At that baseline, `flutter analyze --no-pub` passed and `flutter test --no-pub` passed 35 tests. Those tests covered line diffing and joining only.

1. **[P1] Pi setup failures could hang** (`pi_provider.dart`). The request stream's controller was created before setup. A setup failure then awaited `close()` on a controller that nothing listened to, and that call never completes. Prompt writes also happened outside the cleanup block.
2. **[P1] A second AI request could overwrite the first** (`editor_screen.dart`, `pi_provider.dart`).
   - Ctrl+K could open a new prompt while a request was loading.
   - Cancel or reject unlocked the UI before the stream ended, so old completion code could clear a newer request's state.
   - The finding asked whether early accept was intended. Decision: keep it, but drain the request before another starts.
3. **[P1] Save completion used a tab index** (`editor_screen.dart`, `editor_state.dart`). An asynchronous save kept the tab's index. If tabs closed during the write, it could rename and mark clean the wrong tab.
4. **[P1] Hot exit proceeded after a persistence failure** (`session_service.dart`, `main.dart`). Write failures only went to `debugPrint`. `flushSync` reported nothing, and both exit paths continued regardless.
5. **[P2] Search ignored text edits** (`editor_screen.dart`, `editor_state.dart`, `editor_tab.dart`). Ordinary text edits did not trigger a search refresh, so match counts, offsets and highlights went stale while Find was open.
6. **[P2] Moving lines detached CR from CRLF** (`editor_screen.dart`). The move split lines only on `\n`. For example, moving the first line of `a\r\nb` down produced `b\na\r`.
7. **[P2] Model configuration failures changed the selection policy** (`pi_provider.dart`, `editor_screen.dart`).
   - Unreadable or malformed settings were treated as absent.
   - A filter matching nothing restored the full catalogue.
   - Fetch failures only hid the loading indicator.
8. **[P3] Redundant model cache and normalization** (`editor_screen.dart`, `ai_prompt_popup.dart`).
   - `_cachedModels` duplicated `_cachedFetchResult.models`.
   - The private thinking picker re-checked a level its caller had already normalized, and silently replaced an invalid one.

**Related contract issue.** `_snapshotTab` fell back to the active tab. That could redirect an accepted AI edit into an unrelated document. It was resolved with R2: there is no fallback, and accept reports "The original tab is no longer open. The AI edit was not applied."

## What did not need redesign

These conclusions from the original review still hold:

- **Word diff.** The word-diff tokenization rules and comparison budget have concrete reasons. They were not benchmarked as part of this review.
- **Diff code sharing.** Line and token LCS share mechanics, but they do not need a generic diff framework.
- **Model identity.** `AiModel` identity as `(provider, id)` is still needed, because Pi exposes several providers.
- **Boundary checks.** Checks at disk and RPC boundaries, and `mounted` checks after asynchronous UI work, guard real failure and lifetime risks.
- **Fix approach.** All fixes stayed direct. They added no state-management, RPC-manager, logging or settings framework, and no dependencies.
