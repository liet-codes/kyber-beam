defmodule Kyber.Delta do
  @moduledoc """
  A Delta is the fundamental unit of change/event in the Kyber system.

  Deltas are immutable records of things that happened — messages received,
  errors routed, plugins loaded, etc. They flow through the system, get stored
  persistently, and drive state mutations via the Reducer.
  """

  @typedoc "Unique identifier for a delta (32-char lowercase hex string, 128 bits of entropy)"
  @type id :: String.t()

  @typedoc "Unix timestamp in milliseconds"
  @type ts :: integer()

  @typedoc "The kind of event (e.g. \"message.received\", \"error.route\")"
  @type kind :: String.t()

  @typedoc "Arbitrary map payload — event-specific data"
  @type payload :: map()

  @typedoc """
  A Delta struct representing a single immutable event.

  Fields:
  - `id` — unique identifier (32-char hex string, see `t:id/0`)
  - `ts` — timestamp in milliseconds since epoch
  - `origin` — where this delta came from (see `Kyber.Delta.Origin`)
  - `kind` — event type string (e.g. \"message.received\")
  - `payload` — arbitrary map of event data
  - `parent_id` — optional ID of a parent delta (for causal chains)
  """
  @type t :: %__MODULE__{
          id: id(),
          ts: ts(),
          origin: Kyber.Delta.Origin.t(),
          kind: kind(),
          payload: payload(),
          parent_id: id() | nil
        }

  defstruct [:id, :ts, :origin, :kind, :payload, :parent_id]

  @doc """
  Build a new Delta with generated ID and current timestamp.

  ## Examples

      iex> delta = Kyber.Delta.new("message.received", %{text: "hello"}, {:human, "user_1"})
      iex> delta.kind
      "message.received"
      iex> is_binary(delta.id)
      true
  """
  @spec new(kind(), payload(), Kyber.Delta.Origin.t(), id() | nil) :: t()
  def new(kind, payload \\ %{}, origin \\ {:system, "unknown"}, parent_id \\ nil) do
    %__MODULE__{
      id: generate_id(),
      ts: System.system_time(:millisecond),
      origin: origin,
      kind: kind,
      payload: payload,
      parent_id: parent_id
    }
  end

  @doc """
  Serialize a Delta to a plain map (JSON-safe).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = delta) do
    %{
      "id" => delta.id,
      "ts" => delta.ts,
      "origin" => Kyber.Delta.Origin.serialize(delta.origin),
      "kind" => delta.kind,
      "payload" => delta.payload,
      "parent_id" => delta.parent_id
    }
  end

  @doc """
  Deserialize a Delta from a plain map (as loaded from JSONL).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      ts: map["ts"],
      origin: Kyber.Delta.Origin.deserialize(map["origin"]),
      kind: map["kind"],
      payload: map["payload"] || %{},
      parent_id: map["parent_id"]
    }
  end

  # Generate a random 32-char lowercase hex ID.
  #
  # This is 16 random bytes (128 bits) encoded as hex — the same entropy as a
  # UUID v4, but without the UUID formatting (no hyphens, no version/variant
  # bits). It is NOT a standards-compliant UUID; it is Kyber's own opaque ID
  # format. Example: "4a7f3c1e9b02d856af31c78e04b26d90"
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

defmodule Kyber.Delta.Origin do
  @moduledoc """
  Origin types for Kyber Deltas — tagged tuples describing where a delta came from.

  ## Types

  - `{:channel, channel, chat_id, sender_id}` — came from a messaging channel
  - `{:cron, schedule}` — triggered by a cron schedule
  - `{:subagent, parent_delta_id}` — produced by a sub-agent
  - `{:tool, tool}` — produced by a tool invocation
  - `{:human, user_id}` — directly from a human user
  - `{:system, reason}` — internal system event
  """

  @type channel_origin :: {:channel, String.t(), String.t(), String.t()}
  @type cron_origin :: {:cron, String.t()}
  @type subagent_origin :: {:subagent, String.t()}
  @type tool_origin :: {:tool, String.t()}
  @type human_origin :: {:human, String.t()}
  @type system_origin :: {:system, String.t()}

  @type t ::
          channel_origin()
          | cron_origin()
          | subagent_origin()
          | tool_origin()
          | human_origin()
          | system_origin()

  @doc "Serialize an origin tagged tuple to a JSON-safe map."
  @spec serialize(t()) :: map()
  def serialize({:channel, channel, chat_id, sender_id}) do
    %{"type" => "channel", "channel" => channel, "chat_id" => chat_id, "sender_id" => sender_id}
  end

  def serialize({:cron, schedule}) do
    %{"type" => "cron", "schedule" => schedule}
  end

  def serialize({:subagent, parent_delta_id}) do
    %{"type" => "subagent", "parent_delta_id" => parent_delta_id}
  end

  def serialize({:tool, tool}) do
    %{"type" => "tool", "tool" => tool}
  end

  def serialize({:human, user_id}) do
    %{"type" => "human", "user_id" => user_id}
  end

  def serialize({:system, reason}) do
    %{"type" => "system", "reason" => reason}
  end

  @doc "Deserialize an origin map back to a tagged tuple."
  @spec deserialize(map()) :: t()
  def deserialize(%{"type" => "channel", "channel" => ch, "chat_id" => cid, "sender_id" => sid}) do
    {:channel, ch, cid, sid}
  end

  def deserialize(%{"type" => "cron", "schedule" => schedule}) do
    {:cron, schedule}
  end

  def deserialize(%{"type" => "subagent", "parent_delta_id" => pid}) do
    {:subagent, pid}
  end

  def deserialize(%{"type" => "tool", "tool" => tool}) do
    {:tool, tool}
  end

  def deserialize(%{"type" => "human", "user_id" => user_id}) do
    {:human, user_id}
  end

  def deserialize(%{"type" => "system", "reason" => reason}) do
    {:system, reason}
  end

  def deserialize(other) do
    {:system, "unknown:#{inspect(other)}"}
  end
end
