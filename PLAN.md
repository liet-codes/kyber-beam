# PLAN.md — Kyber-Beam Work Tracker

*Living document. Update in every PR. Never leave bugs unflagged.*

## Backlog

### Bugs (Pre-existing)

- [x] **5 cron test failures** — Fixed! Tests now use Delta.Store.subscribe() instead of query_deltas() because cron.fired deltas are ephemeral (broadcast_only, not persisted). Also added persist_path: nil and isolated store_path to prevent loading production jobs.

### Features

- [x] **Session rehydration** — Conversation history survives restarts. `Kyber.Session` queries the delta store for `message.received` and `llm.response` deltas on init, rebuilds per-chat history (sorted by timestamp), and populates ETS before `start_link/1` returns. PR #4.
- [x] **Slash commands** — Register Discord slash commands (`/ask`, `/status`, `/context`, `/history`, `/forget`). PR #5.
- [x] **Embed support** — Rich embeds in responses (code blocks, structured output). PR #5.
- [x] **File/image sending** — Send files and images from LLM responses. PR #5.

### Tech Debt

- [x] **Startup script** — `com.liet.kyber-beam.plist` + `scripts/start.sh` + `scripts/install.sh`. Loads token from `.env`, KeepAlive/RunAtLoad, logs to `~/.kyber/logs/`. PR #3.
- [x] **Vault path unification** — `@vault_path` now uses `Application.compile_env/3`. Configured in `config/config.exs`, overridable via `KYBER_VAULT_PATH` or `config/runtime.exs`. Tests use isolated temp dir. PR #3.

## Completed

### 2026-03-20

- [x] **Identity crisis fix** — Correct bot token, explicit env var on startup
- [x] **Typing indicator** — `send_typing` effect before `llm_call`
- [x] **👀 reaction** — `add_reaction` on message receipt
- [x] **Reply detection** — Respond to replies, not just @mentions
- [x] **Reply threading** — Responses appear as Discord replies (message_reference)
- [x] **Vault consolidation** — `priv/vault` → symlink to `~/.kyber/vault`
- [x] **Memory grounding** — Mandatory vault-check instruction in system prompt
- [x] **SOUL.md cleanup** — Remove inline definitions, point to vault concepts/
- [x] **Consolidator error handling** — try/rescue/catch around scoring tasks
- [x] **delete_message capability** — REST + effect handler + snowflake validation + tests
- [x] **Compiler warnings** — Clause grouping in tool_executor.ex and gateway.ex
- [x] **PR workflow established** — Branch → PR → staff review → merge
- [x] **#bot-test channel** — Integration test channel with cleanup workflow
