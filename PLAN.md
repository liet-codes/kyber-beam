     1|# Kyber-BEAM Work Tracker
     2|
     3|*Living document. Update in every PR. Defines the state of the repository, the active backlog, and the long-term vision.*
     4|
     5|## 1. Current State (What Works)
     6|Kyber-BEAM is an Elixir/OTP agent harness built on a unidirectional dataflow architecture (Delta → Reducer → Effect).
     7|- **Core Engine:** Append-only delta log, pure reducer, capability-based executor.
     8|- **Discord Integration:** Gateway connection, message routing, rich embeds, thread support.
     9|- **Tool System:** Extensible tool executor with allowlist sandboxing (`exec`, `web_fetch`, image capture).
    10|- **Quality of Life:** Token budget management (180K window), rate limiting (30/min), SSE streaming responses.
    11|- **Memory Infrastructure:** Mounts a local Obsidian vault (`priv/vault`), capable of reading L0/L1 definitions.
    12|
    13|## 2. Active Backlog (P3 & P4 Features)
    14|The foundation is solid; the focus is now on establishing Multiplicity (Agentic Width) and the Rhizome (Memory pipeline).
    15|
    16|### Priority 1: The Rhizome (Memory Phase Transitions)
The architecture must embrace the concept of **Input Saturation as a Phase Transition**. A function invocation is a domain node that exists in a gaseous (purely potential) state until its required inputs condense into it. When it becomes fully applied (reaches the "liquid state"), it executes. 
In practice (V0), this means restructuring the Reducer to eliminate imperative orchestrator chains. The LLM does not "wait" for memory; it simply does not fire until a `prompt.annotated` delta drops into the system.

- [ ] **Phase-Transition Prompting:** Break the imperative `message.received -> llm_call` chain. `message.received` should emit a `prompt.submitted` delta.
- [ ] **The Annotator (Condensation):** Build the handler that intercepts `prompt.submitted`, performs the L0/L1 Obsidian RAG, and emits a `prompt.annotated` delta containing the fully saturated context.
- [ ] **The Inference Trigger:** Update the Reducer so the LLM handler only wakes up when it sees a `prompt.annotated` delta.
- [ ] **Memory Daemon:** Build the daily background process that reads the `delta` log, extracts facts, and performs ADD/UPDATE/DELETE operations on the Obsidian vault.
- [ ] **Semantic Vault Search / Link Traversal:** Upgrade from keyword matching to traversing `[[wikilinks]]` and semantic similarities.

### Priority 2: Multiplicity (Agentic Capabilities)
    22|- [ ] **Sub-agent Orchestration:** Implement `delegate_task` equivalent to spawn and manage parallel OTP processes for independent, simultaneous agent workflows (escaping the single-threaded thought loop).
    23|- [ ] **Skills System:** Implement procedural memory mapping to markdown SOPs (`SKILL.md` equivalents).
    24|
    25|### Priority 3: Deterritorialization (External Agency)
    26|- [ ] **Browser Automation:** Integrate headless browser control to interact with SPAs.
    27|- [ ] **Web Search:** Dedicated search index integration.
    28|
    29|## 3. Long-Term Vision: Rhizomatic Cognition
    30|Kyber is not a tree; it is grass. Its architecture is built around Deleuze & Guattari's concept of the Rhizome.
    31|1. **Event Sourcing over Categorization:** The append-only delta log preserves the history of *how* a connection was made. Connections form through *use*, not forced hierarchical taxonomy.
    32|2. **Sovereignty & Transparency:** All memory is human-readable markdown in a local Obsidian vault. The agent and the human collaborate in the same topological space.
    33|3. **Multiplicity:** The system must support concurrent, non-hierarchical processes (hence Elixir/OTP and sub-agents) that can fork, fold, and share context without a centralized "master" brain blocking operation.