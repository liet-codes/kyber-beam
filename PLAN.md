# PLAN.md — Kyber-Beam Work Tracker

*Living document. Update in every PR. Never leave bugs unflagged.*

## Backlog

### Bugs (Pre-existing)

- [ ] **5 cron test failures** — Tests fail on master (pre-date today's changes). Delta store path issues in test environment. Affected tests:
  - `test job firing emits cron.fired delta when core is set`
  - `test job persistence reminders include label in delta payload`
  - `test job persistence one-shot jobs in the past are fired immediately on reload`
  - `test missed job detection job that fires late gets missed: true in delta`
  - `test missed job detection job that fires on time gets missed: false in delta`
  - Root cause suspected: `priv/data/deltas.jsonl` path resolution in test env

### Features

- [ ] **Session rehydration** — Conversation history lost on restart (ETS in-memory only). Rehydrate from delta log on boot so Stilgar keeps context across restarts.
- [ ] **Slash commands** — Register Discord slash commands (`/ask`, `/status`, `/context`, `/history`, `/forget`)
- [ ] **Embed support** — Rich embeds in responses (code blocks, structured output)
- [ ] **File/image sending** — Send files and images from LLM responses

### Tech Debt

- [ ] **Startup script** — Replace manual `DISCORD_BOT_TOKEN="..." nohup mix run --no-halt &` with a proper startup script or launchd plist that sets the correct token
- [ ] **Vault path unification** — `@vault_path` in tool_executor.ex is hardcoded to `~/.kyber/vault`. Should read from config or application env for testability.

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
