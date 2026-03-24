# Key Conventions: Atoms vs Strings

Kyber-beam uses maps pervasively — for delta payloads, effects, internal state,
JSON from external APIs, and serialized data. This document codifies the
conventions for when to use atom keys (`%{foo: 1}`) vs string keys
(`%{"foo" => 1}`), and how to avoid the subtle bugs that arise from mixing them.

## The Rule

| Context | Key type | Rationale |
|---|---|---|
| **Internal state** (structs, GenServer state, in-memory maps) | Atoms | Idiomatic Elixir; pattern-matchable; compile-time checked |
| **External data** (JSON from APIs, delta payloads, HTTP params) | Strings | `Jason.decode/1` produces string keys; no atom table exhaustion risk |
| **Effect maps** (top-level keys) | Atoms | Created internally by the reducer; never from external input |
| **Effect payloads** (nested under `:payload`) | Strings | Forwarded from delta payloads, which are string-keyed |
| **Serialization boundaries** (JSON files, ETS persistence) | Strings out, atoms in | Convert at the boundary — serialize to strings, deserialize to atoms |

**One-liner:** External data stays string-keyed. Internal state uses atoms.
Convert explicitly at the boundary.

## How It Works in Practice

### Delta payloads: always string keys

Delta payloads originate from external sources (Discord webhooks, HTTP API,
JSON files) and flow through the system without key conversion:

```elixir
# ✅ Correct — string keys in payload
delta = Kyber.Delta.new("message.received", %{
  "text" => "hello",
  "channel_id" => "123456",
  "author_id" => "789"
})

# ✅ Correct — access with string keys
channel_id = Map.get(delta.payload, "channel_id")
text = delta.payload["text"]
```

```elixir
# ❌ Wrong — atom keys in a delta payload
delta = Kyber.Delta.new("message.received", %{
  text: "hello",
  channel_id: "123456"
})

# ❌ Wrong — atom access on string-keyed map (silently returns nil)
channel_id = delta.payload[:channel_id]  # => nil!
```

### Effect maps: atom keys at top level, string keys in payload

Effects are created by the reducer (internal code) with atom top-level keys,
but their `:payload` contains string-keyed data forwarded from deltas:

```elixir
# ✅ Correct — atom keys for structure, string keys in payload
%{
  type: :send_message,
  delta_id: delta.id,
  origin: delta.origin,
  payload: %{"channel_id" => "123", "content" => "hello"}
}

# ✅ Correct — accessing in effect handlers
channel_id = get_in(effect, [:payload, "channel_id"])
content = get_in(effect, [:payload, "content"])
```

```elixir
# ❌ Wrong — string keys at top level
%{"type" => :send_message, "payload" => %{...}}

# ❌ Wrong — atom keys in payload
%{type: :send_message, payload: %{channel_id: "123"}}
```

### Structs and internal state: atom keys

Elixir structs enforce atom keys. Internal state maps (GenServer state,
ETS entries, in-process accumulators) should also use atoms:

```elixir
# ✅ Internal state — atom keys
%{type: "text", text: "", thinking: ""}
block[:text]  # works

# ✅ Struct access
state.plugins
delta.kind
```

### Serialization boundaries: convert explicitly

When reading from or writing to JSON/disk, convert at the boundary:

```elixir
# Writing to JSON (atoms → strings happens via Jason)
Jason.encode!(%{id: mem.id, vault_ref: mem.vault_ref})

# Reading from JSON — string keys come back, convert to atoms
defp map_to_memory(map) do
  %{
    id: Map.get(map, "id"),
    vault_ref: Map.get(map, "vault_ref"),
    salience: Map.get(map, "salience"),
    pinned: Map.get(map, "pinned", false)
  }
end
```

See `Kyber.Memory.Consolidator.memory_to_json/1` and `map_to_memory/1` for a
clean example of this pattern.

## Common Pitfalls

### 1. Accessing string-keyed maps with atom syntax

```elixir
payload = %{"channel_id" => "123"}

payload[:channel_id]   # => nil (silent failure!)
payload.channel_id     # => ** (KeyError) — at least this crashes
payload["channel_id"]  # => "123" ✅
```

### 2. Defensive dual-access (code smell)

```elixir
# This works but indicates uncertainty about key types — fix the source instead
name = Map.get(payload, "name") || Map.get(payload, :name, "unknown")
```

If you find yourself writing dual-access, trace the data back to its origin
and ensure consistent key types.

### 3. `String.to_atom/1` on external input

Never convert external string keys to atoms without bounds:

```elixir
# ❌ Dangerous — unbounded atom creation from external input
map = Map.new(json_map, fn {k, v} -> {String.to_atom(k), v} end)

# ✅ Safe — only convert known keys
map = Map.new(json_map, fn {k, v} -> {String.to_existing_atom(k), v} end)

# ✅ Better — convert only specific keys you expect
%{
  name: Map.get(json_map, "name"),
  value: Map.get(json_map, "value")
}
```

### 4. Pattern matching across key types

```elixir
# ❌ Won't match if payload has string keys
def handle(%{payload: %{channel_id: cid}}), do: ...

# ✅ Match string keys explicitly
def handle(%{payload: %{"channel_id" => cid}}), do: ...
```

## Where Key Types Change

These are the main boundary points in the codebase:

1. **JSON decode** (`Jason.decode/1`) → string keys. All HTTP handlers,
   WebSocket frames, and file reads produce string-keyed maps.

2. **Delta creation** (`Kyber.Delta.new/4`) → payload stays as-given.
   By convention, always pass string-keyed payloads.

3. **Reducer → Effects** → top-level atom keys (`:type`, `:payload`, `:origin`),
   payload contents stay string-keyed.

4. **Memory persistence** (`memory_to_json/1` / `map_to_memory/1`) →
   explicit conversion at the boundary.

5. **Cron job serialization** (`Kyber.Cron`) → jobs stored as string-keyed
   JSON, hydrated to atom-keyed structs on load.

## Quick Reference

| Want to... | Do this |
|---|---|
| Read a delta payload field | `Map.get(delta.payload, "field")` or `delta.payload["field"]` |
| Read an effect's type | `effect.type` or `effect[:type]` |
| Read an effect's payload field | `get_in(effect, [:payload, "field"])` |
| Create an effect | `%{type: :foo, payload: %{"key" => "val"}}` |
| Serialize to JSON | Pass atom-keyed map to `Jason.encode!/1` (converts automatically) |
| Deserialize from JSON | Extract string keys explicitly into atom-keyed struct/map |
