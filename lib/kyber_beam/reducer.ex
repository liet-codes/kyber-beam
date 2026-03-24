defmodule Kyber.Reducer do
  @moduledoc """
  Pure reducer — no GenServer, no side effects.

  Takes a `%Kyber.State{}` and a `%Kyber.Delta{}` and returns
  `{new_state, effects}` where `effects` is a list of effect descriptors
  to be executed asynchronously by `Kyber.Effect.Executor`.

  ## Effect format

  Effects are plain maps with at minimum a `:type` key:

      %{type: :llm_call, delta_id: "...", payload: %{...}}

  ## Pattern dispatch

  | `delta.kind`         | State change               | Effects emitted          |
  |----------------------|----------------------------|--------------------------|
  | `"message.received"` | none                       | `[llm_call effect]`      |
  | `"llm.response"`     | none                       | `[:send_message effect]` |
  | `"llm.error"`        | append to `state.errors`   | `[]`                     |
  | `"error.route"`      | append to `state.errors`   | `[]`                     |
  | `"plugin.loaded"`    | prepend to `state.plugins` | `[]`                     |
  | _(any other)_        | none                       | `[]`                     |
  """

  @typedoc """
  An effect descriptor — a plain map with at minimum a `:type` key (atom).

  The `Kyber.Effect` struct no longer exists; effects are always plain maps.
  Handlers are registered by type in `Kyber.Effect.Executor`.

  Example:

      %{type: :llm_call,   delta_id: "...", payload: %{...}, origin: ...}
      %{type: :send_message, delta_id: "...", payload: %{...}, origin: ...}
  """
  @type effect :: map()
  @type result :: {Kyber.State.t(), [effect()]}

  @doc """
  Reduce a state with a delta, returning `{new_state, effects}`.

  This is a pure function — no side effects, no process calls.
  """
  @spec reduce(Kyber.State.t(), Kyber.Delta.t()) :: result()
  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "message.received"} = delta) do
    channel_id =
      case delta.origin do
        {:channel, "discord", cid, _} -> cid
        _ -> Map.get(delta.payload, "channel_id")
      end

    message_id = Map.get(delta.payload, "message_id")

    # Show typing indicator while LLM processes
    typing_effect =
      if channel_id do
        %{type: :send_typing, origin: delta.origin, payload: %{"channel_id" => channel_id}}
      end

    # React with 👀 to acknowledge receipt
    reaction_effect =
      if channel_id && message_id do
        %{type: :add_reaction, origin: delta.origin,
          payload: %{"channel_id" => channel_id, "message_id" => message_id, "emoji" => "👀"}}
      end

    # Strip "system" from the payload before forwarding to LLM.
    # An unauthenticated POST /api/deltas could inject a "message.received"
    # delta with "system" set to override the system prompt (M-3 Security Audit).
    safe_payload = Map.delete(delta.payload, "system")

    llm_effect = %{
      type: :llm_call,
      delta_id: delta.id,
      payload: safe_payload,
      origin: delta.origin
    }

    effects = Enum.reject([typing_effect, reaction_effect, llm_effect], &is_nil/1)

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "error.route"} = delta) do
    error = %{
      delta_id: delta.id,
      ts: delta.ts,
      payload: delta.payload
    }

    new_state = Kyber.State.add_error(state, error)
    {new_state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "llm.response"} = delta) do
    # Extract the channel from the delta origin or payload (fallback)
    # Emit a :send_message effect so the response gets routed back to the caller
    content = Map.get(delta.payload, "content", "")

    # Derive channel_id from origin first, then payload fallback
    channel_id =
      case delta.origin do
        {:channel, "discord", cid, _} -> cid
        _ -> Map.get(delta.payload, "channel_id")
      end

    reply_to = Map.get(delta.payload, "reply_to_message_id")

    effects =
      if channel_id && content != "" do
        send_payload =
          %{"channel_id" => channel_id, "content" => content}
          |> then(fn p -> if reply_to, do: Map.put(p, "reply_to", reply_to), else: p end)

        [%{
          type: :send_message,
          delta_id: delta.id,
          origin: delta.origin,
          payload: send_payload
        }]
      else
        []
      end

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "llm.error"} = delta) do
    error = %{
      delta_id: delta.id,
      ts: delta.ts,
      payload: delta.payload,
      kind: "llm.error"
    }

    new_state = Kyber.State.add_error(state, error)
    {new_state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "plugin.loaded"} = delta) do
    # Support both string and atom keys — plugin.loaded deltas may originate
    # from internal code (atom keys) or external API (string keys).
    # See docs/CONVENTIONS.md for key conventions.
    plugin_name = Map.get(delta.payload, "name") || Map.get(delta.payload, :name, "unknown")
    new_state = Kyber.State.add_plugin(state, plugin_name)
    {new_state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "cron.fired"} = delta) do
    # When a cron job fires, optionally emit an :llm_call for heartbeat jobs,
    # or let downstream subscribers handle it via pattern matching.
    job_name = Map.get(delta.payload, "job_name", "")

    effects =
      if job_name == "heartbeat" do
        [%{
          type: :llm_call,
          delta_id: delta.id,
          payload: %{"text" => "[heartbeat] check in"},
          origin: delta.origin
        }]
      else
        []
      end

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "familiard.escalation"} = delta) do
    # Escalation events may trigger an LLM call or a direct message,
    # depending on severity level.
    level = Map.get(delta.payload, "level", "info")
    message = Map.get(delta.payload, "message", "")

    effects =
      case level do
        "critical" ->
          [%{
            type: :llm_call,
            delta_id: delta.id,
            payload: %{"text" => "[CRITICAL escalation from familiard] #{message}"},
            origin: delta.origin
          }]

        "warning" ->
          [%{
            type: :llm_call,
            delta_id: delta.id,
            payload: %{"text" => "[warning from familiard] #{message}"},
            origin: delta.origin
          }]

        _ ->
          []
      end

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "task.result"}) do
    # Task results are informational — visible to LLM in subsequent turns
    # via the delta stream. No state change or effects needed.
    {state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "task.error"}) do
    # Task errors are informational — visible to LLM in subsequent turns.
    {state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "search.results"}) do
    # Search results are informational — visible to LLM in subsequent turns
    # via the delta stream. No state change or effects needed.
    {state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "voice.audio"}) do
    # Audio data is passed through; no state change.
    # Downstream effect handlers (e.g. :send_audio) are not emitted here —
    # they're registered by consumers of the voice plugin.
    {state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{}) do
    {state, []}
  end
end
