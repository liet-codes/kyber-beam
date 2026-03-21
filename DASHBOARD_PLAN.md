# Kyber Dashboard — LiveView Observability

## Goal
Real-time under-the-hood view into Stilgar. Answer at a glance:
- Is he alive? What's he doing right now?
- What tools is he calling? Any errors?
- What conversations are active?
- Cron jobs — what's scheduled, what fired?
- BEAM health — processes, memory, schedulers

Replace "hey Liet, is Stilgar up?" with a browser tab.

## Architecture

### Stack
- **Phoenix LiveView** — already in deps, zero JS needed
- **Phoenix.PubSub** — already in deps, broadcast delta events
- **Bandit** — already the HTTP server, Phoenix rides on top
- **Delta subscriptions** — `Kyber.Delta.Store.subscribe` for real-time stream

### Key Insight
Everything in kyber-beam is already a delta. Tool calls, LLM responses, messages,
cron fires, errors — all flow through the delta store. The dashboard is just a
LiveView that subscribes to the delta stream and renders it.

## Pages

### 1. Overview (`/dashboard`)
- **Status pill**: 🟢 Online / 🔴 Down / 🟡 Degraded
- **Uptime**: how long since last restart
- **Active conversations**: count + last activity
- **BEAM vitals**: process count, memory, scheduler util, message queue depth
- **Recent activity**: last 20 deltas (filterable by kind)

### 2. Live Feed (`/dashboard/feed`)
- Real-time delta stream (like `tail -f` but structured)
- Filter by delta kind: `message.received`, `llm.response`, `tool_use`, `cron.fired`, etc.
- Click to expand full payload
- Color-coded: green=success, red=error, yellow=warning, blue=info

### 3. Conversations (`/dashboard/conversations`)
- List of active chat_ids with message counts
- Click into a conversation to see the full exchange
- Show which tools were called during each turn
- Session rehydration status

### 4. Tool Calls (`/dashboard/tools`)
- Timeline of tool executions
- Input/output/error for each call
- Aggregate stats: most used tools, error rates
- Filter by tool name, status, time range

### 5. Cron (`/dashboard/cron`)
- All registered jobs with schedule, next fire, fire count
- Enable/disable toggles (LiveView form → GenServer call)
- Fire history with timestamps
- Add/remove jobs from the UI

### 6. Trace View (`/dashboard/trace`)
- **OTEL-style causal chains**: follow a request from trigger to completion
- Every delta has `parent_id` — build a tree from the lineage
- Visual: indented tree with status icons (✅ ⏳ ❌), durations, expandable payloads
- Example: `message.received → llm_call → tool_use: camera_snap → tool_result → tool_use: view_image → ...`
- Click any node to see full input/output
- Highlight the critical path (longest chain)
- Filter by: active traces, errored traces, slow traces (>Ns)
- **Requires**: emit `tool.start` / `tool.complete` deltas with elapsed_ms for duration tracking

### 7. LLM Context Inspector (in Trace View)
- When expanding an `llm_call` node, show the full context sent to the API:
  - **System prompt**: expandable, shows SOUL.md content, MEMORY.md, daily note
  - **Knowledge vault context**: which notes were loaded, their L0/L1/L2 tier
  - **Conversation history**: the messages array sent to Anthropic
  - **Tool definitions**: which tools were available (collapsible list)
  - **Response**: full response with token usage, model, stop_reason
- This means `llm_call` deltas need to capture the system prompt + messages sent

### 8. BEAM Inspector (`/dashboard/beam`)
- Process tree (supervision hierarchy)
- Per-process memory and message queue
- ETS table sizes
- Scheduler utilization over time (sparklines)

## Implementation Plan

### Phase 1: Foundation (MVP)
1. Add Phoenix Endpoint + Router + Layout
2. Wire PubSub into Delta.Store (broadcast on every append)
3. Overview page with status, uptime, vitals
4. Live feed with delta stream

### Phase 2: Trace View + Tools
5. Add `tool.start` / `tool.complete` deltas with elapsed_ms
6. Trace tree builder (parent_id chain → nested tree)
7. Trace view LiveView — expandable tree with status/duration
8. Tool call timeline with expand/collapse

### Phase 3: Conversations + Cron + BEAM
9. Conversation list + detail view
10. Cron dashboard with toggles
11. BEAM inspector

### Phase 4: Polish
9. Tailwind styling (or simple CSS — no build step needed)
10. Authentication (bearer token, same as API)
11. Mobile-friendly layout

## Technical Notes

- Phoenix can share the Bandit server — just mount the Endpoint in the supervision tree
- PubSub topic: `"deltas"` — broadcast `{:delta, delta}` on every store append
- LiveView handles: `handle_info({:delta, delta}, socket)` → push to stream
- No database needed — everything comes from delta store + GenServer state
- Auth: reuse the existing bearer token from API endpoints

## Port
- Dashboard on same port as API (existing Bandit), or separate port (configurable)
- Default: same port, mounted at `/dashboard/*`

## Dependencies
All already declared in mix.exs:
- `phoenix ~> 1.7` ✅
- `phoenix_live_view ~> 1.0` ✅
- `phoenix_html ~> 4.0` ✅
- `phoenix_pubsub ~> 2.1` ✅
- `phoenix_live_dashboard ~> 0.8` ✅ (bonus: free BEAM dashboard)
