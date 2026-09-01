# Pi Integration Hardening Plan

Findings from an audit of Clankpad's AI integration against the locally installed
Pi **0.84.1** (`docs/rpc.md`, `CHANGELOG.md`, and `dist/` source). The RPC
stdin/stdout integration remains Pi's officially recommended path for non-Node
embedders — the new experimental remote-session client (`PiClient`, CBOR over
Unix socket) is Node-only and not a fit. No architectural change is needed;
the items below are correctness and hygiene fixes, ranked by severity.

Status legend: each item ends with a **Decision** line to fill in during review.

---

## 1. `agent_end` is not a safe terminal event — truncated output can be accepted

**Severity: correctness bug (data corruption path).**
File: `lib/services/pi_provider.dart` (stream loop in `streamEdit`).

### Problem

The stream loop breaks on the **first** `agent_end`. Since Pi introduced
session-level auto-retry (on by default: `retry.enabled: true`, 3 attempts,
2s/4s/8s backoff), `agent_end` means "one low-level run finished — **may be
followed by a retry**" and carries `willRetry`. The settled terminal event is
now `agent_settled` (added in #6363 for exactly this).

Concrete failure modes today:

- **Transient error mid-stream** (529 / rate limit / 5xx): Pi emits `agent_end
  {willRetry: true}` and retries. Clankpad breaks at that `agent_end`, closes
  the controller, and presents the *partial* deltas as a complete diff the user
  can accept — the same corruption the Claude provider explicitly guards
  against with its exit-code check.
- The background retry then streams into a `null` `_lineController`, and can
  still be running when the next `streamEdit` sends `new_session`.
- The existing `auto_retry_end {success: false}` handler is **dead code** —
  the loop has always exited at the preceding `agent_end` before it arrives.
- **Non-transient failure** (auth error, 400): the assistant message ends with
  `stopReason: "error"`, then `agent_end` fires. `stopReason` is never
  inspected, so this surfaces as a "successful" empty/partial diff instead of
  an error banner.

### Proposal A — disable auto-retry, make `agent_end` truly terminal (recommended)

Rationale: for a modal, editor-locking, single-shot edit, silently waiting
2–14 s of backoff behind a progress bar is worse UX than an immediate error
banner and a manual resubmit (`Ctrl+K`, `↑`, `Enter`). Disabling retry also
keeps the provider's `Stream<String>` contract intact — no duplicate-delta
problem (see Proposal B).

Changes in `pi_provider.dart`:

1. In `_spawnProcess` (or first `_ensureRunning`), send once:
   `{"type": "set_auto_retry", "enabled": false}` via `sendCommand`.
2. In the stream loop, on `agent_end`, inspect `event['messages']`:
   - last assistant message `stopReason == "error"` → throw
     `AiProviderError(errorMessage ?? generic)`;
   - `stopReason == "aborted"` → complete normally (existing abort flow);
   - otherwise → complete normally (current behavior).
3. Delete the now-unreachable `auto_retry_end` handler.

Net: ~10 lines changed, one handler removed, one failure path added.

### Proposal B — keep auto-retry, terminate on `agent_settled` (alternative)

Break the loop on `agent_settled` instead of `agent_end`. Correct per the new
protocol, **but** a retry re-streams the assistant response from scratch, so
the append-only `Stream<String>` chunk contract would duplicate text in the
diff. Fixing that requires a reset signal — e.g. changing `streamEdit` to
`Stream<AiEditEvent>` with `reset` / `chunk` variants, and teaching
`EditorScreen._submitAiPrompt` to clear `_diffProposed` on `reset`. Also needs
UX for "retrying (attempt 2/3)…" in the progress area to explain multi-second
stalls.

More code, a wider interface, and a new abstraction for a case Proposal A
sidesteps entirely. Only worth it if silent resilience to transient provider
errors is judged more valuable than immediate feedback.

**Recommendation: A.**
**Decision:** _pending discussion._

---

## 2. Context files leak into the replaced system prompt

**Severity: prompt-quality bug, one-flag fix.**
File: `lib/services/pi_provider.dart` (`_spawnProcess` args).

### Problem

Per Pi's CLI reference, `--system-prompt` *replaces the default prompt* but
**"context files and skills still appended."** Skills are already disabled via
`--no-skills`; context files are not. So:

- a user-level `~/.pi/agent/AGENTS.md` (always trusted, always loaded), or
- an `AGENTS.md` / `CLAUDE.md` in whatever cwd Clankpad inherits
  (`Process.start` is called without `workingDirectory`),

gets appended after the carefully written editor-assistant prompt, re-biasing
the model toward exactly the coding-agent behavior that prompt exists to
suppress.

### Proposal (single approach — no real alternatives)

1. Add `--no-context-files` (`-nc`) to the Pi spawn args, next to the other
   `--no-*` flags, with a one-line comment citing the "context files and
   skills still appended" clause.
2. Defense in depth: pass an explicit neutral `workingDirectory` to
   `Process.start` — the session directory parent (`%APPDATA%\Clankpad`) is a
   natural choice since it always exists by the time AI runs. This also
   insulates against any future cwd-relative Pi behavior.

For parity, check whether the Claude Code provider has the same leak
(`claude -p` loads `CLAUDE.md` from cwd): if so, apply the equivalent
mitigation there (at minimum the same neutral `workingDirectory`; optionally
`--setting-sources` if the installed CLI supports it).

**Decision:** _pending discussion._

---

## 3. `enabledModels` filtering diverges from Pi's real matching semantics

**Severity: silent misbehavior — the documented example config matches nothing.**
File: `lib/services/pi_provider.dart` (`matchesEnabledPattern`,
`loadEnabledModelPatterns`).

### Problem

Clankpad matches `*`-only globs, case-sensitively, against `provider/id` only.
Pi (`dist/core/model-resolver.js`) matches with `minimatch` (`*`, `?`, `[]`),
case-insensitively, against **both** `provider/id` and bare `id`, strips
`:<thinking>` suffixes, and resolves glob-free patterns via
exact/substring/alias fuzzy matching.

Result: Pi's own documented example —
`"enabledModels": ["claude-*", "gpt-4o", "gemini-2*"]` — matches **zero**
models in Clankpad (`claude-*` never matches `anthropic/claude-…`; `gpt-4o`
without a `*` becomes a full-string regex that fails against
`openai/gpt-4o`). The fallback-to-all-models guard prevents a blank dropdown
but silently ignores the user's setting.

Note: there is still no RPC command returning the scoped list
(`get_available_models` returns everything), so client-side filtering remains
necessary — it just has to match Pi's rules.

### Proposal A — align the matcher with Pi's semantics (recommended)

Rewrite `matchesEnabledPattern` (~10 lines, still dependency-free):

1. Strip a trailing `:<suffix>` from the pattern (thinking-level notation).
2. Lowercase pattern and candidates.
3. If the pattern contains `*` / `?`: translate to regex (`*` → `.*`,
   `?` → `.`, escape the rest) and test against **both** `id` and
   `provider/id`. (Supporting `[...]` classes is optional; Pi's docs examples
   never use them — document the omission in a comment.)
4. If glob-free: substring match against `id` (Pi's fuzzy tier that matters
   in practice; full alias/date-preference resolution is deliberately out of
   scope since we filter a list rather than resolve to one model).

Keep the existing "empty result → show all" fallback. Extend the existing
matcher tests (`test/`) with the documented example config as a fixture.

### Proposal B — drop client-side filtering entirely (simpler, worse)

Delete `loadEnabledModelPatterns` / `matchesEnabledPattern` and always show
the full catalogue. Removes ~40 lines and the settings.json parsing, but users
with a large `models.json` lose the curated dropdown, and the feature already
exists and is tested. Only preferable if we judge the semantics drift risk
(tracking Pi's matcher over time) higher than the feature's value.

**Recommendation: A.**
**Decision:** _pending discussion._

---

## 4. Minor / optional improvements

Each is independent; adopt or reject individually.

### 4a. Per-model thinking levels via `get_available_thinking_levels`

Today the UI infers levels from the `reasoning` capability bit and normalizes
Pi's full range (`minimal`…`xhigh`, `max`) down to off/low/medium/high
(`_normaliseLevel`). That is a defensible simplification and sending `high` is
always valid.

- **Proposal:** leave as is. Revisit only if users ask for `xhigh`/`max`
  (GPT-5.6, adaptive Claude); then call the RPC command
  `get_available_thinking_levels` after model selection and show its exact
  list instead of the fixed four. Costs one round trip per model change and a
  dynamic picker.

### 4b. Skip redundant `set_model` / `set_thinking_level` round trips

`streamEdit` sends both before every prompt. Caching the last-sent values in
`PiProvider` and skipping unchanged ones saves two of three awaited round
trips per submit.

- **Proposal:** skip. Local-pipe round trips are ~ms; the cache adds two
  fields plus invalidation-on-respawn for no perceptible gain. Revisit only if
  submit latency becomes measurable.

### 4c. Friendlier first-run diagnostics via `pi auth check` (new in 0.84.1)

Distinguish "pi installed but not authenticated" from generic failures.

- **Proposal:** cheapest meaningful version — when `fetchModels` returns an
  empty catalogue or the first prompt fails with an auth-looking error, append
  a hint to the banner: "run `pi /login` in a terminal". A full
  `pi auth check` preflight subprocess at startup adds a process launch on the
  hot path for a rare condition; not worth it.

### 4d. Claude Code hardcoded model catalogue rot

Already acknowledged in a code comment; nothing in Pi 0.84.1 changes this
(it's a Claude Code limitation — no queryable model list).

- **Proposal:** no action. Keep the comment as the maintenance marker.

### 4e. (Product idea, out of scope here) Reusable edit commands

Pi prompt templates + RPC `get_commands` could surface user-defined commands
(`/proofread`, `/formalize`) in the Ctrl+K popup: remove
`--no-prompt-templates` from the spawn args, call `get_commands`, and offer
completions. Deliberately **not** part of this hardening plan — track in
`FEATURES.md` if wanted.

---

## Explicit non-changes (verified correct against 0.84.1)

Recorded so future audits don't re-litigate them:

- **LF framing:** Dart's `LineSplitter` splits only on CR/LF (never
  U+2028/U+2029, which JSON escapes anyway) — compliant with Pi's strict JSONL
  requirement.
- **`message_update` breaking change (0.84.0):** Clankpad already reads only
  `assistantMessageEvent.delta`; the removed cumulative `message` field was
  never used.
- **Warm RPC process, lazy spawn on popup-open, awaited id-tagged setup
  sequence, `--no-session` + `new_session` per edit, stderr drain,
  `runInShell` for Windows `.cmd`, prompt-via-stdin for Claude, partial-diff
  auto-reject:** all correct and justified; keep.

---

## Suggested execution order

1. Item 2 (`--no-context-files` + `workingDirectory`) — two lines, zero risk.
2. Item 1 Proposal A (retry/termination semantics) — the actual bug fix;
   includes deleting the dead `auto_retry_end` handler and adding a
   `stopReason` check; extend provider tests with an error-run fixture.
3. Item 3 Proposal A (matcher alignment) — with the documented example config
   as a regression test.
4. Item 4c hint text, if adopted.
