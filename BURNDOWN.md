# Kyber-Beam Burndown — Post-Audit

*Generated 2026-03-23 from three independent code reviews (Elixir Expert, Harness Architect, Power User)*

---

## P0 — Security (fix before any deployment)

- [x] **Exec allowlist bypass** — `String.split(~r/[\s|;&]/)` only checks first token; `git; rm -rf /` passes. Added `contains_shell_injection?/1` guard that rejects shell metacharacters before allowlist check. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/tool_executor.ex`

- [x] **BearerAuth plug not wired** — `POST /api/deltas` was fully unauthenticated. Wired `BearerAuth` plug into router pipeline, excluded `/health` endpoint. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/web/router.ex`

- [x] **Web router bypasses Core.emit** — `POST /api/deltas` now routes through `Kyber.Core.emit/2` instead of direct `Store.append`. Ensures ephemeral filtering and system key stripping. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/web/router.ex`

---

## P1 — Performance & Reliability (fix before sustained use)

- [ ] **O(n) session history append** — `history ++ [delta]` copies full list every message. Degrades at ~200+ messages/session.
  - File: `lib/kyber_beam/session.ex` ~line 110
  - Fix: Prepend (`[delta | history]`), reverse on read

- [ ] **O(n) `trim_memory` on every delta append** — `length(deltas)` is O(n), runs every append.
  - File: `lib/kyber_beam/delta/store.ex` ~line 165
  - Fix: Track `delta_count` in state

- [ ] **LLM re-registration race** — after Core restart, `llm_call` effects silently dropped during 500ms polling loop before re-registration completes.
  - File: `lib/kyber_beam/plugin/llm.ex` ~line 170
  - Fix: Use `Process.monitor/1` on new Executor PID, re-register in `:DOWN` handler

- [ ] **No API retry/backoff** — transient 5xx/429 from Anthropic silently kills turns.
  - File: `lib/kyber_beam/plugin/llm.ex`, `call_api/2`
  - Fix: Exponential backoff (1s, 2s, 4s), 3 retries on 5xx

- [ ] **Knowledge reload race** — no guard against concurrent reload tasks during polling.
  - File: `lib/kyber_beam/knowledge.ex` ~line 255
  - Fix: Track `reload_task_ref` in state, skip poll when reload in progress

- [ ] **Delta.Store disk query blocks GenServer** — `Task.yield/2` inside `handle_call` blocks for up to 5s.
  - File: `lib/kyber_beam/delta/store.ex` ~line 130
  - Fix: Deferred reply via `GenServer.reply/2`

---

## P2 — Architecture Consistency (fix for code health)

- [ ] **LLM + Discord plugins bypass Plugin.Manager** — started directly in `application.ex`, violating "plugins all the way down" principle. Not hot-reloadable, not in plugin list, no `plugin.loaded` deltas.
  - File: `lib/kyber_beam/application.ex`
  - Fix: Start via `Plugin.Manager`, define formal `Plugin` behaviour

- [ ] **Effect struct vs plain maps** — `Kyber.Effect` struct exists but reducer produces plain maps. Struct's `data` field is never used.
  - Files: `lib/kyber_beam/effect.ex`, `lib/kyber_beam/reducer.ex`
  - Fix: Either delete struct or migrate reducer to use it

- [ ] **Session started before Core** — `Kyber.Session` in supervisor before `Kyber.Core`. Rehydration with `delta_store:` would reference an unstarted store.
  - File: `lib/kyber_beam/application.ex`
  - Fix: Move Session after Core in children list

- [ ] **`reinforce_memories/1` hardcodes ETS table name** — `:ets.whereis(:memory_pool)` bypasses Consolidator API.
  - File: `lib/kyber_beam/plugin/llm.ex`
  - Fix: Call through `Kyber.Memory.Consolidator` public API

---

## P3 — Missing Features (for daily-driver viability)

- [ ] **LLM streaming** — 60s synchronous waits. Poor UX, Discord shows "thinking..." indefinitely.
- [ ] **Sub-agent orchestration** — no spawn, no delegation, no parallel work. Biggest feature gap vs OpenClaw.
- [ ] **Browser automation** — no equivalent to OpenClaw's browser tool.
- [ ] **Web search** — only `web_fetch` (raw HTTP), no search index integration.
- [ ] **Multi-channel support** — Discord only. No WhatsApp, Telegram, Signal, etc.
- [ ] **Rate limiting** — no cost protection on LLM calls.
- [ ] **Token budget management** — 20-message heuristic instead of actual token counting.
- [ ] **README / onboarding** — README says "TODO: Add description". No getting started guide.
- [ ] **Skills system** — no equivalent to OpenClaw's AgentSkills (SKILL.md).
- [ ] **Multi-model support** — hardcoded claude-sonnet-4 in several places.

---

## P4 — Design Doc Gaps (aspirational → implemented)

- [ ] **Memory extraction pipeline** — docs describe Extract → Compare → ADD/UPDATE/DELETE/NOOP. Not implemented.
- [ ] **Delta state rebuild** — Design Principle 1 claims "Replay the log, get the same state." Not actually functional. Need snapshot mechanism.
- [ ] **L0/L1 auto-generation** — docs describe Haiku generating L0/L1 summaries from L2. Currently L0 = title+tags, L1 = first paragraph.
- [ ] **Semantic vault search** — keyword only until Phase 3.
- [ ] **Tool trust rings** — docs describe per-tool trust levels. Not implemented.
- [ ] **Formal Plugin behaviour** — docs describe `init/1`, `handle_effect/2`, `shutdown/1`, `secrets/0`, `capabilities/0`. No `@callback` definitions exist.

---

## Minor / Nits

- [ ] `PipelineWirer` in `core.ex` — extract to own file if it grows
- [ ] `toggle_job/2` dead code in `cron.ex` — unreachable fallback clause
- [ ] Delta IDs are 32-char hex, not UUID — document or switch
- [ ] `Kyber.Knowledge.frontmatter_to_yaml` — naive serializer, breaks on nested maps
- [ ] `Consolidator` logs `inspect/1` on large lists — truncate or log count only
- [ ] `Process.sleep` in integration tests — use `assert_receive` with timeout
- [ ] Discord gateway URL fetched but discarded — use it for proper sharding
- [ ] `find_match` in `cron.ex` can recurse 525K times — run in Task for rare expressions

---

*Total: ~~3~~ 0 P0 (all fixed!) + 6 P1 (perf/reliability) + 4 P2 (architecture) + 10 P3 (features) + 6 P4 (doc gaps) + 8 nits = 34 remaining items*
