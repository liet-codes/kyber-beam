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
The foundation is solid; the focus is now on establishing Multiplicity (Agentic Width) and the Rhizome (Memory pipeline).

### Priority 1: The Rhizome (Memory Extraction Pipeline)
- [ ] **Memory Daemon:** Build the process that reads the daily `delta` log, extracts facts/concepts, and performs ADD/UPDATE/DELETE operations on the Obsidian vault.
- [ ] **L0/L1 Auto-generation:** Implement the LLM translation step that generates the ~100-token L0 index and ~2k-token L1 summary from full L2 context.
- [ ] **Semantic Vault Search / Link Traversal:** Upgrade from keyword matching to traversing `[[wikilinks]]` and semantic similarities, allowing the agent to follow lines of flight through its own memory.

### Priority 2: Multiplicity (Agentic Capabilities)
- [ ] **Sub-agent Orchestration:** Implement `delegate_task` equivalent to spawn and manage parallel OTP processes for independent, simultaneous agent workflows (escaping the single-threaded thought loop).
- [ ] **Skills System:** Implement procedural memory mapping to markdown SOPs (`SKILL.md` equivalents).

### Priority 3: Deterritorialization (External Agency)
- [ ] **Browser Automation:** Integrate headless browser control to interact with SPAs.
- [ ] **Web Search:** Dedicated search index integration.

## 3. Long-Term Vision: Rhizomatic Cognition
Kyber is not a tree; it is grass. Its architecture is built around Deleuze & Guattari's concept of the Rhizome.
1. **Event Sourcing over Categorization:** The append-only delta log preserves the history of *how* a connection was made. Connections form through *use*, not forced hierarchical taxonomy.
2. **Sovereignty & Transparency:** All memory is human-readable markdown in a local Obsidian vault. The agent and the human collaborate in the same topological space.
3. **Multiplicity:** The system must support concurrent, non-hierarchical processes (hence Elixir/OTP and sub-agents) that can fork, fold, and share context without a centralized "master" brain blocking operation.