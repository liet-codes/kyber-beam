# Expert Review: kyber-beam Agent Harness

*Reviewed by: subagent (Liet/OpenClaw, harness architecture specialist)*
*Date: 2026-03-23*
*Codebase: lib/ (~11.5K LOC, 40 files) + docs/*

---

## Executive Summary

kyber-beam is a genuinely thoughtful personal agent harness built in Elixir/OTP that trades production-readiness for architectural purity. The delta-driven event-sourcing core (`Kyber.Core` → `Kyber.Reducer` → `Kyber.Effect.Executor`) is clean, well-reasoned, and aligns with the best patterns in the event-sourcing tradition — the pure-function reducer, supervised effect dispatch, and append-only delta log are all correctly implemented. The memory system (`Kyber.Knowledge` + `Kyber.Memory.Consolidator`) is among the most thoughtful personal-agent memory designs I've seen: the L0/L1/L2 tiered context model, salience-based decay, and Obsidian vault integration are genuinely innovative for a personal agent harness. However, the codebase has a significant gap between its design docs and current implementation: the "plugins all the way down" principle is violated by the application supervisor, exec security has a critical bypass flaw, delta state rebuild is conceptually promised but not actually implemented, and several design-doc aspirations (semantic search, extraction pipeline, tool trust rings) exist only in docs. This is excellent Alpha-quality engineering with B-grade production readiness.

---

## 1. Architecture Assessment: Delta-Driven Model, Plugin System, Core Loop

### Core Loop (`core.ex`, `reducer.ex`, `effect.ex`)

**The architecture is sound.** The supervision tree in `Kyber.Core` follows `:rest_for_one` correctly — if `Delta.Store` crashes, `PipelineWirer` also restarts to re-subscribe, preventing stale subscriptions. This is not an obvious choice and it's the right one.

`PipelineWirer` is a clever solution to the "how do we wire subscriptions after startup" problem: started last in the supervision tree, its `init/1` is guaranteed all prior siblings are already up. No sleep hacks, no retry loops. Clean.

The reducer (`Kyber.Reducer`) is genuinely pure — a plain Elixir module with pattern-matched function clauses, no GenServer calls, no I/O. This is architecturally correct and enables deterministic testing. The effect descriptor pattern (plain maps with `:type`) is simple and works.

**Concerns:**

1. **Delta replay is aspirational, not implemented.** Design Principle 1 says "Replay the log, get the same state." But `Kyber.Reducer` only handles `message.received`, `llm.response`, `llm.error`, `plugin.loaded`, `cron.fired`, etc. — largely triggering *new effects* rather than rebuilding state. The `Kyber.State` struct (`sessions`, `plugins`, `errors`) is mostly populated by live events. Replaying the delta log would not reconstruct a meaningful conversational state. There's no snapshot mechanism. The delta log is effectively an event log for observability, not a true state reconstruction mechanism. **This is a real gap between the design docs' claims and the implementation.**

2. **The State struct is anemic.** `Kyber.State` holds `plugins`, `errors`, and `sessions` — but `sessions` is never actually populated by the reducer. Session state lives in `Kyber.Session` (ETS-backed GenServer). The State struct is mostly decorative. This isn't wrong, but it means the "current state is a materialized view of the delta log" claim is more marketing than implementation.

3. **Ephemeral delta distinction is good.** The decision to skip persisting `cron.fired` deltas (which fired at ~2.6/sec) while still broadcasting them is exactly right — and the comment documenting the 400K+ delta incident that motivated it is excellent engineering culture.

### Plugin System (`plugin/manager.ex`)

`Kyber.Plugin.Manager` is a `DynamicSupervisor` with `register/unregister/reload/list`. The implementation is clean. Hot-reload works: `reload/2` terminates the child and restarts it.

**Critical inconsistency:** The application supervisor (`application.ex`) starts `Kyber.Plugin.LLM` and `Kyber.Plugin.Discord` **directly**, bypassing `Plugin.Manager`. This is acknowledged in the design docs as a "known inconsistency." The effect is that the two most important plugins are not reloadable via `Plugin.Manager.reload/2`, their lifecycle is not tracked in the plugin list, and they do not emit `plugin.loaded` deltas the way the design intends. For a system whose Design Principle 7 says "Plugins all the way down," this is a meaningful architectural debt.

**No formal `Plugin` behaviour.** The codebase has no `@callback` definitions for what a plugin must implement. The docs describe a rich interface (`init/1`, `handle_effect/2`, `shutdown/1`, `secrets/0`, `capabilities/0`). The code enforces only `start_link/1` (via `DynamicSupervisor.start_child`). Trust rings exist only in the docs.

---

## 2. LLM Integration Quality (`plugin/llm.ex`)

### What Works Well

- **OAuth vs API key detection** via `detect_auth_type/1` (prefix matching on token) is simple and correct. The dynamic auth-config fetch pattern (`plugin_pid = self()` before the closure, then `GenServer.call(plugin_pid, :get_auth_config)` at invocation time) correctly prevents stale token capture in closures.

- **Multi-turn tool loop** in `run_tool_loop/7` is correctly implemented: accumulates `assistant_msg` + `user_result_msg` into the message list on each iteration, recurses until `stop_reason == "end_turn"` or max 10 iterations. Tool call and result deltas are emitted for observability at each step.

- **Session management** (store user message before API call, store assistant response after) is correctly sequenced. Using `Kyber.Session` as the conversation memory, keyed by `chat_id_from_origin`, gives channel-scoped history isolation.

- **Image support** via the `{:ok_image, ...}` return tuple from `view_image` is cleanly handled — the tool loop converts it to a proper Anthropic `image` content block inline.

- **Executor re-registration after restart** (`:DOWN` monitor + `:reregister_after_core_restart` retry loop) is solid resilience engineering.

### Concerns

1. **No token counting.** The 20-message history cap (`Enum.take(-20)`) is a heuristic. For claude-sonnet-4 with 200K context, this is fine. For models with smaller windows, or long messages, it could cause context overflow. There is no token-budget-aware history truncation.

2. **No streaming.** `Req.post/3` with a 60-second timeout waits for the full response. For long completions (8192 max_tokens), this creates user-visible latency. Streaming with `receive_timeout` + chunked response would dramatically improve UX.

3. **No retry logic on API failure.** `call_api/2` returns `{:error, ...}` and the tool loop propagates it upward. A transient 529 "overloaded" error kills the turn. Exponential backoff with 2-3 retries on 5xx would be trivial to add.

4. **`reinforce_memories/1` couples LLM plugin to ETS internals.** The function does `:ets.whereis(:memory_pool)` — hardcoded table name. If `Kyber.Memory.Consolidator` is started with a custom name (multi-instance), this silently fails to reinforce anything. Should go through the `Consolidator` public API.

5. **System prompt construction** in `build_system_prompt/1` ignores the `chat_id` argument entirely. The function signature suggests channel-specific prompts, but all channels get the same prompt. The hardcoded `vault_instruction` and `capabilities_note` strings are config that should live in the vault.

6. **Security**: The reducer correctly strips the `"system"` key from incoming `message.received` payloads before forwarding to the LLM effect. This prevents prompt injection via unauthenticated API delta injection (noted in `reducer.ex` comment as M-3 Security Audit fix). **Good catch, correctly implemented.**

---

## 3. Tool System Assessment (`tools.ex`, `tool_executor.ex`)

### What Works Well

- **SSRF guard in `web_fetch`** is correctly implemented: blocks `localhost`, `127.0.0.1`, `169.254.169.254`, RFC-1918 ranges, `.internal` domains. IPv6 bracket stripping is handled.

- **Path restrictions** for `read_file`/`write_file` are runtime-evaluated (not module attributes) — correctly avoids the build-time `$HOME` trap documented in the Architecture Audit.

- **`view_image` returning `{:ok_image, ...}`** rather than `{:ok, string}` is a clean type-level distinction that lets the LLM plugin construct proper multimodal content blocks.

- **The BEAM introspection tools** (`beam_memory`, `beam_genserver_state`, `beam_supervision_tree`, `beam_reload_module`, etc.) are unique and excellent. The ability for the agent to inspect its own runtime — memory pressure, message queue health, module hot-reload — is something OpenClaw and Claude Code cannot do. This is a genuine architectural differentiator.

### Concerns

1. **Critical exec security flaw.** The allowlist check:
   ```elixir
   cmd_stem = cmd |> String.trim() |> String.split(~r/[\s|;&]/, parts: 2) |> List.first("")
   if cmd_stem not in @allowed_exec_commands do ...
   ```
   This splits on the first space/pipe/semicolon. `"git; rm -rf /"` yields `cmd_stem = "git"` — which IS in the allowlist. The `sh -c` execution then runs both `git` and `rm -rf /`. Any allowlisted command can be chained with arbitrary shell code via `;`, `&&`, `||`, `|`. This is a bypass-able allowlist, not a real sandbox. **For a personal machine with a trusted LLM, this is tolerable risk. For anything beyond personal use, this is a critical vulnerability.**

2. **`String.to_existing_atom` in BEAM tools.** Multiple tool handlers do `String.to_existing_atom(name)` and rescue `ArgumentError`. This is safe, but the rescue returns `{:error, "Unknown process name: #{name}"}` rather than surfacing the ArgumentError — which is the correct behavior. The wrapping is fine.

3. **No formal tool behavior contract.** Tools are static entries in `@tools` (module attribute list). Adding a tool means: edit `@tools` in `tools.ex`, add an `execute/2` clause in `tool_executor.ex`. There is no `defbehaviour`, no compile-time check that every definition has an executor, no runtime registration. The design doc describes dynamic tool registration — the implementation is a hardcoded list.

4. **`set_channel_context` uses process dictionary.** This is documented and intentional (tool loop runs in a single Task). It works, but it's fragile if concurrent tool executions ever happen in the same process, and it makes `send_file` implicitly depend on prior LLM plugin execution.

5. **No timeout isolation per tool.** The `exec` tool has a configurable `timeout_ms`. Other tools (web_fetch, camera_snap) have hardcoded timeouts. A slow `web_fetch` blocks the tool loop Task for 10 seconds. No per-tool timeout configuration is exposed.

---

## 4. Memory/Knowledge System (`knowledge.ex`, `memory/consolidator.ex`)

### What Works Well

This is the strongest part of the codebase.

- **`Kyber.Knowledge`** is genuinely well-engineered: Obsidian-compatible vault, YAML frontmatter parsing, incremental mtime-based polling (only re-reads changed files), wikilink extraction, subscriber notification, async reload via `Task` + `handle_info({:reload_complete, ...})`. The GenServer is never blocked on file I/O during steady-state operation.

- **L0/L1/L2 tiered context** is cleanly implemented in `tiered_context/2`. L0 = title + type + tags (~100 tokens), L1 = frontmatter + first paragraph (~500 tokens), L2 = full note. The `memory_read` tool correctly exposes this tier parameter to the LLM.

- **`Kyber.Memory.Consolidator` salience model** is more sophisticated than I expected: ETS pool of vault note references with float salience, tag-based reinforcement (buffered + applied atomically), exponential decay (0.95× per cycle), grace period for recently reinforced memories, GC of dead vault refs and low-salience entries, pinning system, MEMORY.md generation from pool, hourly consolidation cycle. The three-layer design (pool JSONL = truth, vault notes = content, MEMORY.md = view) is architecturally clean.

- **`vault_changed` → async scoring Task → `scoring_complete`** debouncing: when vault files change, Haiku is called to score salience. If scoring is in progress when new changes arrive, paths are buffered and processed in the next batch. This is correct concurrent design.

- **MEMORY.md "drifting" section** uses stratified random sampling (oldest/middle/newest quartiles) to expose low-salience but potentially relevant memories. This is more thoughtful than pure top-N selection.

### Concerns

1. **L0/L1 auto-generation is NOT implemented.** The memory architecture doc describes: "Background task generates L1 summary from L2 (cheap model — Haiku). L0 one-liner generated from L1." The vault polling reloads files but `Kyber.Memory.Consolidator` scores new notes for salience — it does NOT generate L0/L1 summaries. L0 is just the frontmatter's `title` + `tags` fields; L1 is literally the first paragraph. The sophisticated bottom-up summarization described in the docs doesn't exist yet.

2. **Vault change scoring makes an LLM API call per changed file.** If the vault has many simultaneous changes (e.g., git pull updating 50 files), this spawns a Task that makes 50 sequential Haiku API calls. No batching, no rate limiting. Could be expensive and slow.

3. **Keyword search only.** `query_notes/2` filters by type, tags, date. `memory_search` tool uses `Kyber.Knowledge.get_tiered`. There is no full-text search, no keyword index, no semantic search. The LLM is expected to know which vault paths to read via `memory_list` + `memory_read`. This works for now but doesn't scale to large vaults.

4. **MEMORY.md uses `enforce_token_budget/4` that re-renders repeatedly.** The approach of render → check size → trim drifting → re-render is correct but O(n²) in the worst case on large drifting pools. Fine for personal use, not scalable.

5. **No extraction pipeline.** The memory architecture doc's centerpiece — the "Extract → Compare → ADD/UPDATE/DELETE/NOOP" pipeline that creates knowledge notes from conversations — is entirely absent from the code. The `Kyber.Memory.Consolidator` scores existing vault notes but does not extract new facts from conversations. This is the biggest gap between design and implementation.

---

## 5. Comparison with OpenClaw and Other Frameworks

### Where kyber-beam Wins

| Dimension | kyber-beam | OpenClaw |
|-----------|-----------|---------|
| **Transparency** | Delta log = full audit trail, files = human-readable ground truth | Black box; internal state not inspectable |
| **Sovereignty** | Runs entirely local, vault is your files | Cloud-dependent, token-bound to Anthropic |
| **BEAM introspection** | Agent can inspect own runtime (memory, processes, ETS, hot-reload) | No equivalent |
| **Session rehydration** | Survives restarts via delta log replay | Session lost on restart |
| **Architecture clarity** | Pure reducer, clean effect boundary, documented design principles | Opaque |
| **Memory design** | L0/L1/L2 tiers, salience model, Obsidian vault | File-based but no tiered loading |
| **Causal tracing** | `parent_id` on every delta, causal chain queryable | None |

### Where OpenClaw Wins

| Dimension | kyber-beam | OpenClaw |
|-----------|-----------|---------|
| **Maturity** | Alpha, known gaps between docs and code | Production, months of use |
| **Streaming** | Not implemented | First-class |
| **Sub-agent orchestration** | `subagent` origin type exists but no multi-agent engine | Sessions, spawn, auto-announce |
| **Tool sandboxing** | Exec allowlist bypassable | OS-level isolation via PTY/node |
| **Skills/plugins** | Hardcoded in lib/ | Hot-installable skill packs |
| **Rate limiting** | None | Handled |
| **Error recovery** | No retry on API failure | Retry + backoff |
| **Multi-model** | Hardcoded claude-sonnet-4 | Configurable per request |

### Versus LangChain / AutoGPT / Other Frameworks

- **vs. LangChain**: kyber-beam's delta architecture is significantly cleaner than LangChain's callback-soup. LangChain is Python-first and better for prototyping with diverse models; kyber-beam is better for a stable, inspectable personal agent.
- **vs. AutoGPT**: Not a comparison. AutoGPT is goal-chasing loops with unreliable memory. kyber-beam is tightly scoped and correct.
- **vs. Letta (MemGPT)**: Letta has a more mature self-editing memory model (the OS-inspired core/recall/archival tiers with agent-invoked memory edits). kyber-beam's vault system is more human-navigable but has no automatic extraction yet. Letta is chat-optimized; kyber-beam is personal-assistant-optimized.
- **vs. Claude Code (internal)**: Claude Code is a coding-specialized tool loop, not a general agent harness. kyber-beam's delta observability gives it better auditability. Claude Code has better tool sandboxing, streaming, and multi-turn error recovery.

---

## 6. What's Missing for Production Readiness

**Blocking:**

1. **Exec security fix** — the allowlist bypass via `;`/`&&`/`||` must be patched before exposing to any adversarial input. Options: use `Path.basename` to extract the binary name and refuse shell metacharacters in the command, or switch to `System.cmd/3` with explicit argv (no `sh -c`).

2. **No rate limiting** on LLM calls. A user flooding the Discord channel can rack up significant API costs. Basic per-channel rate limiting (e.g., token bucket) is needed.

3. **API error retry** — transient 5xx/429 errors silently kill turns. Two-line fix: wrap `call_api/2` with exponential backoff (1s, 2s, 4s).

**Important:**

4. **Streaming LLM responses** — 60-second synchronous waits for long generations create poor UX. Discord shows "thinking..." indefinitely. Streaming to Discord requires chunked message updates or progressive typing.

5. **LLM and Discord plugins outside Plugin.Manager** — violates the core design principle, makes hot-reload and observability of these plugins impossible through the intended interface.

6. **No token budget management** — replacing the 20-message heuristic with actual token counting would prevent context overflow on verbose conversations.

7. **Extraction pipeline not implemented** — the centerpiece of the memory architecture doc. Without it, the vault only grows through explicit agent tool calls, not automatic knowledge extraction.

8. **Delta state rebuild not actually functional** — the delta log is an audit trail but cannot reconstruct meaningful application state from scratch. A snapshot + replay mechanism is needed if the guarantee in Design Principle 1 is to be honored.

**Nice to have:**

9. **Semantic/keyword search over vault** — `memory_list` + manual `memory_read` doesn't scale past ~50 notes.

10. **Multi-model support** — hardcoded `@default_model "claude-sonnet-4-20250514"` everywhere. Haiku for cheap tasks (consolidation, scoring) is called with the same model name as the main conversation model in some places.

11. **Process dictionary for channel context** (`set_channel_context/1`) should be replaced with explicit parameter passing to `send_file` to avoid fragility.

---

## 7. Overall Grade: **B+**

**Justification:**

The architectural bones are excellent — better than most hobbyist agent harnesses and better designed than some production ones. The delta-driven core, pure reducer, supervised effects, and `PipelineWirer` startup sequencing show deep OTP understanding. The memory system's salience model, L0/L1/L2 tiers, and vault integration are genuinely innovative for this scale.

The deductions come from the gap between design docs and implementation (extraction pipeline, true state rebuild, trust rings, formal plugin behaviour), the exec security flaw that makes the system unsafe against any adversarial LLM output, and missing production staples (streaming, rate limiting, retry).

This is strong Alpha software: it works correctly for its intended use case (personal assistant, single trusted user, Anthropic API), has thoughtful architecture that will pay dividends as features are added, and has design documentation that's better than most production agent frameworks. With 2-3 weeks of hardening it could be a solid B+ system for personal deployment. With the full design-doc roadmap executed, it could be an A.

**Component Grades:**
- Core architecture / delta model: **A-**
- LLM integration: **B**
- Tool system: **C+** (exec security flaw prevents higher)
- Memory/knowledge system: **B+**
- Plugin architecture: **B-** (good design, implementation inconsistency)
- Session management: **A-**
- Documentation / design coherence: **A**

---

*"The code should be boring. The architecture should be interesting." — kyber-beam design-principles.md. The architecture is genuinely interesting. The code is mostly boring, in the right way, with a few exceptions that need attention.*
