# AI Provider Refactor — Adding Claude Code

## Context

Clankpad currently has a single AI provider: **Pi** (`pi --mode rpc`). This document analyzes how to add **Claude Code** (`claude -p`) as a second provider and proposes a minimal refactor to support both.

---

## How Claude Code works as a provider

From the docs, Claude Code communicates via `claude -p` with `--output-format stream-json --verbose --include-partial-messages`. Key differences from Pi's RPC:

| Aspect                 | Pi (`pi --mode rpc`)                                          | Claude Code (`claude -p`)                                                                                      |
| ---------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Lifecycle**          | Long-lived process, kept warm                                 | One process per request (or `--resume` for conversation continuation)                                          |
| **Protocol**           | JSON-RPC over stdin/stdout (bidirectional)                    | Stdin prompt at launch time, stream-json on stdout (one-shot)                                                  |
| **Model list**         | `get_available_models` command                                | Not queryable — Claude Code uses whatever model Anthropic's API gives it (user configures via `claude config`) |
| **Model switching**    | `set_model` / `set_thinking_level` commands                   | `--model` flag at launch time                                                                                  |
| **Streaming**          | `message_update` events with `text_delta`                     | `stream_event` with `event.delta.type == "text_delta"`                                                         |
| **Abort**              | `{"type":"abort"}` on stdin                                   | Kill the process                                                                                               |
| **Completion**         | `agent_end` event                                             | Process exits / final `result` message                                                                         |
| **Prompt engineering** | Clankpad builds the prompt string, sends via `prompt` command | Same prompt string, passed via `-p` flag                                                                       |

---

## Proposed architecture

The cleanest refactor introduces a **thin provider abstraction** — just enough to swap the streaming backend, without over-engineering:

```
lib/services/
  ai_provider.dart          ← abstract interface (new)
  pi_provider.dart           ← Pi RPC implementation (renamed/refactored from pi_rpc_service.dart)
  claude_code_provider.dart  ← Claude Code implementation (new)
```

### The interface (minimal)

```dart
abstract class AiProvider {
  String get name;                        // "Pi" / "Claude Code"

  /// Returns available models, or empty list if not queryable.
  Future<List<Map<String, dynamic>>> fetchModels();

  /// Streams edited text chunks. Same contract as today's streamEdit.
  Stream<String> streamEdit({
    required String documentText,
    required String editTarget,
    required String userInstruction,
    String? modelProvider,
    String? modelId,
    String thinkingLevel,
    int? insertOffset,
  });

  void abort();
  Future<void> dispose();

  /// Non-fatal warning from last call (e.g. model switch failed).
  String? get lastWarning;
}
```

### Key design decisions

1. **Provider selection in the popup** — add a provider toggle (simple segmented button or dropdown) above or beside the model picker. When "Claude Code" is selected, the model dropdown either hides (Claude Code manages its own model) or shows Claude Code's models if queryable.

2. **Model list** — Pi fetches dynamically. Claude Code doesn't have a `get_available_models` equivalent from the CLI, so either:
   - (a) Hard-code known Claude models (fragile), or
   - (b) Show no model picker for Claude Code and let `--model` be optional (simplest — user configures via `claude config`), or
   - (c) Let user type/pick a model string that gets passed as `--model` flag

   Recommendation: **(b)** as simplest — the Claude Code provider just uses whatever model is configured. If the user wants a specific model, they run `claude config set model <name>`.

3. **Prompt construction** — `_buildPromptMessage` is the same for both providers (it's just a text prompt). Move it to a shared utility or keep it in the base class.

4. **Session persistence** — `lastProvider` field (alongside `lastModelProvider`/`lastModelId`). When restoring, if persisted provider is "claude_code" but Claude Code isn't available (not on PATH), silently fall back to Pi.

5. **Claude Code streaming** — parse `stream-json` events:

   ```
   claude -p "..." --output-format stream-json --verbose --include-partial-messages \
     --allowedTools "" --append-system-prompt "Reply with ONLY the transformed text..."
   ```

   Filter for `type == "stream_event"` where `event.delta.type == "text_delta"`, yield `event.delta.text`.

6. **No tools for Claude Code** — pass `--allowedTools ""` so it can't read/edit files. We just want text generation, same as Pi.

---

## What changes in `EditorScreen`

- Hold a `Map<String, AiProvider>` (e.g. `{'pi': PiProvider(), 'claude_code': ClaudeCodeProvider()}`)
- `_selectedProviderKey` string replaces the implicit "always Pi" assumption
- Model fetching becomes `_activeProvider.fetchModels()`
- Streaming becomes `_activeProvider.streamEdit(...)`
- Abort becomes `_activeProvider.abort()`

## What stays the same

- All UI code (diff view, prompt popup, tab bar, editor area)
- Prompt construction logic
- Session persistence structure (just add `lastProviderKey`)
- Diff accept/reject flow

---

## Implementation phases

Three phases. Each leaves the app in a working, `flutter analyze`-clean state.

### Phase 1 — Extract interface + refactor Pi into it ✅

**Goal**: introduce the `AiProvider` abstraction without adding any new functionality. App works exactly as before.

- [x] Create `lib/services/ai_provider.dart` with the abstract class (`AiProvider`, `AiProviderModels`, `AiProviderError`, shared `buildPromptMessage`).
- [x] Move `_buildPromptMessage` from `PiRpcService` into `AiProvider` as a shared static method.
- [x] Rename `lib/services/pi_rpc_service.dart` → `lib/services/pi_provider.dart`; class `PiRpcService` → `PiProvider implements AiProvider`.
- [x] Adapt `PiProvider` to satisfy the interface (`fetchModels` absorbs warm-up + 3 parallel fetches + filtering; `lastWarning` replaces `lastModelSwitchError`).
- [x] Update `lib/screens/editor_screen.dart`: field type `AiProvider`, all call sites updated (`fetchModels`, `streamEdit`, `abort`, `dispose`, `lastWarning`, `AiProviderError`). No behavioural change.
- [x] Delete old `lib/services/pi_rpc_service.dart`.
- [x] Verify: `flutter analyze` clean — **No issues found**.

### Phase 2 — Implement Claude Code provider

**Goal**: add `ClaudeCodeProvider` implementing `AiProvider`. No UI wiring yet — it's a standalone, testable unit.

- [ ] Create `lib/services/claude_code_provider.dart`.
- [ ] Spawn `claude -p "<prompt>" --output-format stream-json --verbose --include-partial-messages --allowedTools ""`.
- [ ] Parse `stream-json` lines: filter `type == "stream_event"` where `event.delta.type == "text_delta"`, yield `event.delta.text`.
- [ ] `abort()` → kill the process.
- [ ] `fetchModels()` → return empty list (Claude Code manages its own model; no queryable model list).
- [ ] `dispose()` → kill process if running.
- [ ] Verify: `flutter analyze` clean.

### Phase 3 — Wire up provider selection + persistence

**Goal**: user can switch between Pi and Claude Code in the Ctrl+K popup; choice persists across restarts.

- [ ] `EditorScreen`: hold `Map<String, AiProvider>` (`'pi'` → `PiProvider`, `'claude_code'` → `ClaudeCodeProvider`); add `_selectedProviderKey` state field.
- [ ] `AiPromptPopup` / `AiModelSettings`: add provider-level selector (segmented button or small dropdown) above the model picker row.
- [ ] When provider is Claude Code: hide model dropdown (no models to pick); show/hide thinking level based on provider capability.
- [ ] Model fetching: call `_activeProvider.fetchModels()` only when provider changes or on first open; cache per provider.
- [ ] `EditorState` + `SessionService`: add `lastProviderKey` field; persist in `session.json`; restore with silent fallback if provider unavailable.
- [ ] Update `SPEC.md` with provider selection docs, session schema, and shortcut/UX notes.
- [ ] Verify: `flutter analyze` clean, both providers work end-to-end.

---

## Summary

This is a clean seam. The current `PiRpcService` already encapsulates all the Pi-specific protocol details. We extract an interface, wrap Claude Code's `claude -p --output-format stream-json` in the same interface, and add a provider selector to the popup. ~3 files changed, ~1–2 new files. Prompt logic and all UI stay untouched.
