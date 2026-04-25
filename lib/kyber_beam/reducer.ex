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

  | `delta.kind`         | State change               | Effects emitted              |
  |----------------------|----------------------------|------------------------------|
  | `"message.received"` | none                       | `[:annotate_prompt effect]`  |
  | `"prompt.annotated"` | none                       | `[:llm_call effect]`         |
  | `"llm.response"`     | none                       | `[:send_message effect]`     |
  | `"llm.error"`        | append to `state.errors`   | `[]`                         |
  | `"error.route"`      | append to `state.errors`   | `[]`                         |
  | `"plugin.loaded"`    | prepend to `state.plugins` | `[]`                         |
  | _(any other)_        | none                       | `[]`                         |

  ## Event-Driven Input Saturation

  `message.received` no longer emits `:llm_call` directly. Instead it emits
  `:annotate_prompt`, which is intercepted by `Kyber.Tools.PromptAnnotator`.
  The annotator enriches the prompt (stub today; memory/RAG retrieval in
  the future) and emits a `prompt.annotated` delta. Only that delta is
  translated into the actual `:llm_call` effect.

  All paths that need to invoke the LLM (`message.received`, `cron.fired`
  heartbeat, `familiard.escalation`) flow through `:annotate_prompt`
  → `prompt.annotated` → `:llm_call`.
  """

  @typedoc """
  An effect descriptor — a plain map with at minimum a `:type` key (atom).

  The `Kyber.Effect` struct no longer exists; effects are always plain maps.
  Handlers are registered by type in `Kyber.Effect.Executor`.

  Example:

      %{type: :annotate_prompt, delta_id: "...", payload: %{...}, origin: ...}
      %{type: :llm_call,        delta_id: "...", payload: %{...}, origin: ...}
      %{type: :send_message,    delta_id: "...", payload: %{...}, origin: ...}
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

    # Strip "system" from the payload before forwarding to the annotator.
    # An unauthenticated POST /api/deltas could inject a "message.received"
    # delta with "system" set to override the system prompt (M-3 Security Audit).
    safe_payload = Map.delete(delta.payload, "system")

    # Event-Driven Input Saturation: the prompt is first handed to the
    # annotator (RAG / memory enrichment lives there). The annotator emits
    # a "prompt.annotated" delta which the reducer translates into :llm_call.
    annotate_effect = %{
      type: :annotate_prompt,
      delta_id: delta.id,
      payload: safe_payload,
      origin: delta.origin
    }

    effects = Enum.reject([typing_effect, reaction_effect, annotate_effect], &is_nil/1)

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "prompt.annotated"} = delta) do
    llm_effect = %{
      type: :llm_call,
      delta_id: delta.id,
      payload: delta.payload,
      origin: delta.origin
    }

    {state, [llm_effect]}
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

    # If streaming or tool preview created a preview message, edit it instead of posting new.
    # Priority: streaming preview > tool preview (tool preview is set via persistent_term)
    streaming_msg_id =
      Map.get(delta.payload, "streaming_message_id") ||
        get_and_clear_tool_preview(channel_id)

    effects =
      if channel_id && content != "" do
        send_payload =
          %{"channel_id" => channel_id, "content" => content}
          |> then(fn p -> if reply_to, do: Map.put(p, "reply_to", reply_to), else: p end)
          |> then(fn p ->
            if streaming_msg_id,
              do: Map.put(p, "edit_message_id", streaming_msg_id),
              else: p
          end)

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

    # Send error to Discord so the user sees what went wrong
    channel_id =
      case delta.origin do
        {:channel, "discord", cid, _} -> cid
        _ -> Map.get(delta.payload, "channel_id")
      end

    error_msg = Map.get(delta.payload, "error", "Unknown error")
    status = Map.get(delta.payload, "status", 0)

    effects =
      if channel_id do
        content = "⚠️ **Error** (#{status}): #{String.slice(error_msg, 0, 500)}"

        # Check for tool preview to edit instead of posting new
        preview_msg_id = get_and_clear_tool_preview(channel_id)

        send_payload =
          %{"channel_id" => channel_id, "content" => content}
          |> then(fn p ->
            if preview_msg_id,
              do: Map.put(p, "edit_message_id", preview_msg_id),
              else: p
          end)

        [%{
          type: :send_message,
          delta_id: delta.id,
          origin: delta.origin,
          payload: send_payload
        }]
      else
        []
      end

    {new_state, effects}
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
    # Heartbeat cron jobs route through the annotator like any other prompt.
    # Non-heartbeat jobs are left for downstream subscribers to handle.
    job_name = Map.get(delta.payload, "job_name", "")

    effects =
      if job_name == "heartbeat" do
        [%{
          type: :annotate_prompt,
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
    # Escalation events go through the annotator first; only critical/warning
    # levels are routed onward to the LLM.
    level = Map.get(delta.payload, "level", "info")
    message = Map.get(delta.payload, "message", "")

    effects =
      case level do
        "critical" ->
          [%{
            type: :annotate_prompt,
            delta_id: delta.id,
            payload: %{"text" => "[CRITICAL escalation from familiard] #{message}"},
            origin: delta.origin
          }]

        "warning" ->
          [%{
            type: :annotate_prompt,
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

  # ── Delta-routed memory writes ───────────────────────────────────────────
  # memory.add and memory.update both emit :vault_write effects.
  # memory.delete emits a :vault_delete effect.
  # The reducer is pure — actual I/O happens in the effect handlers.

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: kind} = delta)
      when kind in ["memory.add", "memory.update"] do
    path = Map.get(delta.payload, "path", "")
    content = Map.get(delta.payload, "content", "")
    reason = Map.get(delta.payload, "reason", "")

    effects = [
      %{
        type: :vault_write,
        delta_id: delta.id,
        path: path,
        content: content,
        reason: reason
      }
    ]

    {state, effects}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "memory.delete"} = delta) do
    path = Map.get(delta.payload, "path", "")
    reason = Map.get(delta.payload, "reason", "")

    effects = [
      %{
        type: :vault_delete,
        delta_id: delta.id,
        path: path,
        reason: reason
      }
    ]

    {state, effects}
  end

  # Confirmation deltas — informational only, no effects.
  def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: kind})
      when kind in ["vault.written", "vault.deleted"] do
    {state, []}
  end

  def reduce(%Kyber.State{} = state, %Kyber.Delta{}) do
    {state, []}
  end

  # Retrieve and clear tool preview message ID stored by the tool loop.
  # Returns nil if no preview exists for this channel.
  defp get_and_clear_tool_preview(nil), do: nil

  defp get_and_clear_tool_preview(channel_id) do
    key = {:tool_preview_msg, channel_id}

    try do
      msg_id = :persistent_term.get(key)
      :persistent_term.erase(key)
      msg_id
    rescue
      ArgumentError -> nil
    end
  end
end
