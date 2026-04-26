     1|     1|     1|     1|# Kyber-BEAM Work Tracker

## 0. Next Ralph Loop: Two-Stage RAG: Stage 2 (LLM Deep Retrieval Tool)
**Objective:** Provide the LLM with a new tool (e.g., `vault_search` or `memory_read`) that allows it to query L1/L2 records dynamically during its execution cycle, leaning on the L0 annotations surfaced in Stage 1.

**Requirements:**
1. Register a new tool in the `Kyber.Plugin.LLM` space corresponding to vault reads.
2. The tool must invoke `Kyber.Knowledge` to retrieve the full markdown content of a specified vault path or entity name.
3. Tests must be updated using an isolated vault and prove the core tool executor can successfully process a `vault_search` tool call emitted by the LLM. No `Process.sleep`.

**Success Criteria:**
- ExUnit tests pass demonstrating the core tool executor can successfully process a `vault_search` tool call emitted by the LLM to read deeper L1/L2 files, returning the correct markdown content.

---


    17|
    18|     2|     2|     2|
    19|     3|     3|     3|*Living document. Update in every PR. Defines the state of the repository, the active backlog, and the long-term vision.*
    20|     4|     4|     4|
    21|     5|     5|     5|## 1. Current State (What Works)
    22|     6|     6|     6|Kyber-BEAM is an Elixir/OTP agent harness built on a unidirectional dataflow architecture (Delta → Reducer → Effect).
    23|     7|     7|     7|- **Core Engine:** Append-only delta log, pure reducer, capability-based executor.
    24|     8|     8|     8|- **Discord Integration:** Gateway connection, message routing, rich embeds, thread support.
    25|     9|     9|     9|- **Tool System:** Extensible tool executor with allowlist sandboxing (`exec`, `web_fetch`, image capture).
    26|    10|    10|    10|- **Quality of Life:** Token budget management (180K window), rate limiting (30/min), SSE streaming responses.
    27|    11|    11|    11|- **Memory Infrastructure:** Mounts a local Obsidian vault (`priv/vault`), capable of reading L0/L1 definitions.
    28|    12|    12|    12|
    29|    13|    13|    13|## 2. Active Backlog (P3 & P4 Features)
    30|    14|    14|    14|The foundation is solid; the focus is now on establishing Multiplicity (Agentic Width) and the Rhizome (Memory pipeline).
    31|    15|    15|    15|
    32|    16|    16|    16|### Priority 1: Event-Driven Input Saturation (Memory & RAG)
    33|    17|The architecture must embrace **Input Saturation** via pure event sourcing. A function invocation (like an LLM call) should not be an imperative chain. Instead, an invocation is a domain node that waits until its required inputs have "condensed" or assembled via the event bus. Only when the inputs are fully saturated does the execution trigger.
    34|    18|In practice, this means restructuring the Reducer to eliminate imperative orchestrator chains. The LLM does not "wait" for memory; it simply does not fire until a fully assembled `prompt.annotated` delta drops into the system.
    35|    19|
    36|    20|- [ ] **Decoupled Prompting:** Break the imperative `message.received -> llm_call` chain. `message.received` should emit a basic `prompt.submitted` delta.
    37|    21|- [ ] **The Annotator (Input Assembly):** Build a handler that intercepts `prompt.submitted`, performs the L0/L1 Obsidian RAG (retrieving memory), and emits a `prompt.annotated` delta containing the fully saturated context.
    38|    22|- [ ] **The Inference Trigger:** Update the Reducer so the LLM handler only wakes up when it sees a `prompt.annotated` delta.
    39|    23|- [ ] **Memory Daemon:** Build the background process that reads the `delta` log, extracts facts, and performs ADD/UPDATE/DELETE operations on the Obsidian vault.
    40|    24|- [ ] **Two-Stage Retrieval:** Replace monolithic RAG with lightweight L0 surfacing injected by the `Annotator` and deep L1/L2 autonomous tool exploration (e.g. `vault_search`).
    41|    25|
    42|    26|### Priority 2: Multiplicity (Agentic Capabilities)
    43|    27|    27|    22|- [ ] **Sub-agent Orchestration:** Implement `delegate_task` equivalent to spawn and manage parallel OTP processes for independent, simultaneous agent workflows (escaping the single-threaded thought loop).
    44|    28|    28|    23|- [ ] **Skills System:** Implement procedural memory mapping to markdown SOPs (`SKILL.md` equivalents).
    45|    29|    29|    24|
    46|    30|    30|    25|### Priority 3: Deterritorialization (External Agency)
    47|    31|    31|    26|- [ ] **Browser Automation:** Integrate headless browser control to interact with SPAs.
    48|    32|    32|    27|- [ ] **Web Search:** Dedicated search index integration.
    49|    33|    33|    28|
    50|    34|    34|    29|## 3. Long-Term Vision: Rhizomatic Cognition
    51|    35|    35|    30|Kyber is not a tree; it is grass. Its architecture is built around Deleuze & Guattari's concept of the Rhizome.
    52|    36|    36|    31|1. **Event Sourcing over Categorization:** The append-only delta log preserves the history of *how* a connection was made. Connections form through *use*, not forced hierarchical taxonomy.
    53|    37|    37|    32|2. **Sovereignty & Transparency:** All memory is human-readable markdown in a local Obsidian vault. The agent and the human collaborate in the same topological space.
    54|    38|    38|    33|3. **Multiplicity:** The system must support concurrent, non-hierarchical processes (hence Elixir/OTP and sub-agents) that can fork, fold, and share context without a centralized "master" brain blocking operation.