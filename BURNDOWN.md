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

- [x] **O(n) session history append** — Prepend O(1) + reverse on read. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/session.ex`

- [x] **O(n) `trim_memory` on every delta append** — Track `delta_count` in state, O(1) check. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/delta/store.ex`

- [x] **LLM re-registration race** — Monitor Executor PID, re-register on `:DOWN`. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/plugin/llm.ex`

- [x] **No API retry/backoff** — Exponential backoff (1s/2s/4s), 3 retries on 5xx, 429 Retry-After. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/plugin/llm.ex`

- [x] **Knowledge reload race** — Track `reload_task_ref`, skip poll when reload in progress. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/knowledge.ex`

- [x] **Delta.Store disk query blocks GenServer** — Deferred reply via `spawn_monitor` + `GenServer.reply/2`. *(Fixed 2026-03-23)*
  - File: `lib/kyber_beam/delta/store.ex`

---

## P2 — Architecture Consistency (fix for code health)

- [x] **LLM + Discord plugins bypass Plugin.Manager** — Now routed through Plugin.Manager via `plugins:` opt. Hot-reloadable, emits `plugin.loaded` deltas. *(Fixed 2026-03-23)*

- [x] **Effect struct vs plain maps** — Deleted unused `Kyber.Effect` struct. Effects are plain maps with `:type` key, documented via `@typedoc`. *(Fixed 2026-03-23)*

- [x] **Session started before Core** — Moved Session after Core in supervisor children. *(Fixed 2026-03-23)*

- [x] **`reinforce_memories/1` hardcodes ETS table name** — Uses `Consolidator.get_pool/0` now. *(Fixed 2026-03-23)*

---

## P3 — Missing Features (for daily-driver viability)

- [ ] **LLM streaming** — 60s synchronous waits. Poor UX, Discord shows "thinking..." indefinitely.
- [ ] **Sub-agent orchestration** — no spawn, no delegation, no parallel work. Biggest feature gap vs OpenClaw.
- [ ] **Browser automation** — no equivalent to OpenClaw's browser tool.
- [ ] **Web search** — only `web_fetch` (raw HTTP), no search index integration.
- [ ] **Multi-channel support** — Discord only. No WhatsApp, Telegram, Signal, etc.
- [ ] **Rate limiting** — no cost protection on LLM calls.
- [ ] **Token budget management** — 20-message heuristic instead of actual token counting.
- [x] **README / onboarding** — README says "TODO: Add description". No getting started guide. *(Fixed 2026-03-23)*
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

- [x] `PipelineWirer` in `core.ex` — extract to own file if it grows *(Fixed 2026-03-23)*
- [x] `toggle_job/2` dead code in `cron.ex` — unreachable fallback clause *(Fixed 2026-03-23)*
- [x] Delta IDs are 32-char hex, not UUID — document or switch *(Fixed 2026-03-23)*
- [ ] `Kyber.Knowledge.frontmatter_to_yaml` — naive serializer, breaks on nested maps
- [ ] `Consolidator` logs `inspect/1` on large lists — truncate or log count only
- [ ] `Process.sleep` in integration tests — use `assert_receive` with timeout
- [x] Discord gateway URL fetched but discarded — use it for proper sharding *(Fixed 2026-03-23)*
- [x] `find_match` in `cron.ex` can recurse 525K times — add max iteration guard *(Fixed 2026-03-23)*

---

*Total: 0 P0 + 0 P1 + 0 P2 (all fixed!) + 9 P3 (features) + 6 P4 (doc gaps) + 3 nits = 18 remaining items*
