# Kyber-BEAM Work Tracker

*Living document. Update in every PR. Defines the state of the repository, the active backlog, and the long-term vision.*

## 1. Current State (What Works)
Kyber-BEAM is an Elixir/OTP agent harness built on a unidirectional dataflow architecture (Delta → Reducer → Effect).
- **Core Engine:** Append-only delta log, pure reducer, capability-based executor.
- **Discord Integration:** Gateway connection, message routing, rich embeds, thread support.
- **Tool System:** Extensible tool executor with allowlist sandboxing (`exec`, `web_fetch`, image capture).
- **Quality of Life:** Token budget management (180K window), rate limiting (30/min), SSE streaming responses.
- **Memory Infrastructure:** Mounts a local Obsidian vault (`priv/vault`), capable of reading L0/L1 definitions.

## 2. Active Backlog (P3 & P4 Features)
The foundation is solid; the focus is now on Agentic Width and the Semantic/Wet Math pipeline.

### High Priority (Agentic Capabilities)
- [ ] **Sub-agent Orchestration:** Implement `delegate_task` equivalent to spawn and manage parallel OTP processes for independent agent workflows.
- [ ] **Browser Automation:** Integrate headless browser control (e.g. Playwright via Elixir or a dedicated tool server) to interact with SPAs.
- [ ] **Skills System:** Implement a procedural memory system mapping to markdown SOPs (`SKILL.md` equivalents).

### High Priority (Memory / "Wet Math" Pipeline)
- [ ] **Memory Extraction Pipeline:** Build the daemon that reads the daily `delta` log, extracts facts, and performs ADD/UPDATE/DELETE operations on the Obsidian vault.
- [ ] **Semantic Vault Search:** Upgrade from keyword matching to FTS5 or an equivalent semantic index over the L0/L1/L2 vault.
- [ ] **L0/L1 Auto-generation:** Implement the LLM translation step that generates the ~100-token L0 index and ~2k-token L1 summary from full L2 context.

### Lower Priority
- [ ] **Web Search:** Dedicated search index integration (beyond just `web_fetch`).
- [ ] **Multi-channel support:** Expand beyond Discord.
- [ ] **Tool Trust Rings:** Implement per-tool execution trust boundaries.

## 3. Long-Term Vision
Kyber is the foundation for an agent operating in the "Liquid State" (Class IV dynamics as defined in the Wet Math framework).
1. **Event Sourcing for Cognition:** The append-only delta log preserves the *calculus of belief*, allowing the agent to fork and inspect its own cognitive history.
2. **Sovereignty & Transparency:** All memory is human-readable markdown in a local Obsidian vault, avoiding black-box vector databases.
3. **Structured Non-Commutativity:** The architecture is designed to support the measurement of the Groovy Commutator ($G(S) \neq 0$), balancing the anabolic (rigid scaffolding) and catabolic (free generation) states of the system.