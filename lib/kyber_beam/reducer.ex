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

  @type effect :: map()
  @type result :: {Kyber.State.t(), [effect()]}

  @doc """
  Reduce a state with a delta, returning `{new_state, effects}`.

  This is a pure function — no side effects, no process calls.
  """
  @spec reduce(Kyber.State.t(), Kyber.Delta.t()) :: result()
  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "message.received"} = delta) do
    effect = %{
      type: :llm_call,
      delta_id: delta.id,
      payload: delta.payload,
      origin: delta.origin
    }

    {state, [effect]}
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
    # Extract the channel from the parent delta's origin (stored in the effect)
    # Emit a :send_message effect so the response gets routed back to the caller
    content = Map.get(delta.payload, "content", "")

    # Derive channel_id from the delta origin (if it's a channel origin)
    channel_id =
      case delta.origin do
        {:channel, "discord", cid, _} -> cid
        _ -> nil
      end

    effects =
      if channel_id && content != "" do
        [%{
          type: :send_message,
          delta_id: delta.id,
          origin: delta.origin,
          payload: %{"channel_id" => channel_id, "content" => content}
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
    plugin_name = Map.get(delta.payload, "name") || Map.get(delta.payload, :name, "unknown")
    new_state = Kyber.State.add_plugin(state, plugin_name)
    {new_state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{}) do
    {state, []}
  end
end
