     1|     1|     1|# Kyber-BEAM Work Tracker

## 0. Next Ralph Loop: Event-Driven Input Saturation (V0)
**Objective:** Break the imperative `message.received -> llm_call` chain to introduce a phase transition (Input Saturation) natively in the event bus.

**Requirements:**
1. Update `Kyber.Reducer` so `message.received` emits a `prompt.submitted` delta (or effect that creates it), rather than directly triggering the LLM.
2. Create a mock Annotator handler (to be replaced with actual RAG later) that intercepts `prompt.submitted` and emits a `prompt.annotated` delta.
3. Update `Kyber.Reducer` so the `:llm_call` effect ONLY fires when it sees a `prompt.annotated` delta.

**Success Criteria:**
- ExUnit tests pass proving `message.received` no longer triggers the LLM directly.
- ExUnit tests pass proving `prompt.annotated` successfully triggers the LLM effect.
- The pipeline functions sequentially in isolation, demonstrating decoupled input saturation.

---

     2|     2|     2|
     3|     3|     3|*Living document. Update in every PR. Defines the state of the repository, the active backlog, and the long-term vision.*
     4|     4|     4|
     5|     5|     5|## 1. Current State (What Works)
     6|     6|     6|Kyber-BEAM is an Elixir/OTP agent harness built on a unidirectional dataflow architecture (Delta → Reducer → Effect).
     7|     7|     7|- **Core Engine:** Append-only delta log, pure reducer, capability-based executor.
     8|     8|     8|- **Discord Integration:** Gateway connection, message routing, rich embeds, thread support.
     9|     9|     9|- **Tool System:** Extensible tool executor with allowlist sandboxing (`exec`, `web_fetch`, image capture).
    10|    10|    10|- **Quality of Life:** Token budget management (180K window), rate limiting (30/min), SSE streaming responses.
    11|    11|    11|- **Memory Infrastructure:** Mounts a local Obsidian vault (`priv/vault`), capable of reading L0/L1 definitions.
    12|    12|    12|
    13|    13|    13|## 2. Active Backlog (P3 & P4 Features)
    14|    14|    14|The foundation is solid; the focus is now on establishing Multiplicity (Agentic Width) and the Rhizome (Memory pipeline).
    15|    15|    15|
    16|    16|    16|### Priority 1: Event-Driven Input Saturation (Memory & RAG)
    17|The architecture must embrace **Input Saturation** via pure event sourcing. A function invocation (like an LLM call) should not be an imperative chain. Instead, an invocation is a domain node that waits until its required inputs have "condensed" or assembled via the event bus. Only when the inputs are fully saturated does the execution trigger.
    18|In practice, this means restructuring the Reducer to eliminate imperative orchestrator chains. The LLM does not "wait" for memory; it simply does not fire until a fully assembled `prompt.annotated` delta drops into the system.
    19|
    20|- [ ] **Decoupled Prompting:** Break the imperative `message.received -> llm_call` chain. `message.received` should emit a basic `prompt.submitted` delta.
    21|- [ ] **The Annotator (Input Assembly):** Build a handler that intercepts `prompt.submitted`, performs the L0/L1 Obsidian RAG (retrieving memory), and emits a `prompt.annotated` delta containing the fully saturated context.
    22|- [ ] **The Inference Trigger:** Update the Reducer so the LLM handler only wakes up when it sees a `prompt.annotated` delta.
    23|- [ ] **Memory Daemon:** Build the background process that reads the `delta` log, extracts facts, and performs ADD/UPDATE/DELETE operations on the Obsidian vault.
    24|- [ ] **Semantic Vault Search:** Upgrade from keyword matching to traversing `[[wikilinks]]`.
    25|
    26|### Priority 2: Multiplicity (Agentic Capabilities)
    27|    27|    22|- [ ] **Sub-agent Orchestration:** Implement `delegate_task` equivalent to spawn and manage parallel OTP processes for independent, simultaneous agent workflows (escaping the single-threaded thought loop).
    28|    28|    23|- [ ] **Skills System:** Implement procedural memory mapping to markdown SOPs (`SKILL.md` equivalents).
    29|    29|    24|
    30|    30|    25|### Priority 3: Deterritorialization (External Agency)
    31|    31|    26|- [ ] **Browser Automation:** Integrate headless browser control to interact with SPAs.
    32|    32|    27|- [ ] **Web Search:** Dedicated search index integration.
    33|    33|    28|
    34|    34|    29|## 3. Long-Term Vision: Rhizomatic Cognition
    35|    35|    30|Kyber is not a tree; it is grass. Its architecture is built around Deleuze & Guattari's concept of the Rhizome.
    36|    36|    31|1. **Event Sourcing over Categorization:** The append-only delta log preserves the history of *how* a connection was made. Connections form through *use*, not forced hierarchical taxonomy.
    37|    37|    32|2. **Sovereignty & Transparency:** All memory is human-readable markdown in a local Obsidian vault. The agent and the human collaborate in the same topological space.
    38|    38|    33|3. **Multiplicity:** The system must support concurrent, non-hierarchical processes (hence Elixir/OTP and sub-agents) that can fork, fold, and share context without a centralized "master" brain blocking operation.