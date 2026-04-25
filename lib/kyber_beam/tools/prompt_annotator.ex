defmodule Kyber.Tools.PromptAnnotator do
  @moduledoc """
  Effect handler for `:annotate_prompt` — the input-saturation phase of
  the Event-Driven prompt pipeline.

  Intercepts an `:annotate_prompt` effect, performs prompt enrichment
  (currently a stub passthrough; will become memory/RAG retrieval), and
  emits a `prompt.annotated` delta back into the system. The reducer
  then translates `prompt.annotated` into the actual `:llm_call` effect.

  The chain:

      message.received → :annotate_prompt → (this handler emits)
        → prompt.annotated → :llm_call

  ## Registration

  Wired through `Kyber.Effect.Executor.execute/2` via `Kyber.Core`:

      Kyber.Tools.PromptAnnotator.register(Kyber.Core)
  """

  require Logger

  @doc """
  Pure transformation: build the `prompt.annotated` delta from an
  `:annotate_prompt` effect map.

  Exposed as a separate function so the annotation logic is testable
  without spinning up a full Core. `register/1` wires the handler into
  the Effect.Executor and re-emits the resulting delta.
  """
  @spec annotate(map()) :: Kyber.Delta.t()
  def annotate(effect) when is_map(effect) do
    payload = Map.get(effect, :payload, %{}) || %{}
    origin = Map.get(effect, :origin) || {:system, "annotator"}
    parent_id = Map.get(effect, :delta_id)

    annotated_payload =
      payload
      |> Map.put("annotations", build_annotations(payload))
      |> Map.put("annotated_at", System.system_time(:millisecond))

    Kyber.Delta.new("prompt.annotated", annotated_payload, origin, parent_id)
  end

  @doc """
  Register the `:annotate_prompt` effect handler with the given Core.

  When the handler fires it computes the `prompt.annotated` delta via
  `annotate/1` and re-emits it through `Kyber.Core.emit/2`, which feeds
  the reducer that produces the downstream `:llm_call` effect.
  """
  @spec register(Supervisor.supervisor()) :: :ok
  def register(core) do
    Kyber.Core.register_effect_handler(core, :annotate_prompt, fn effect ->
      delta = annotate(effect)

      try do
        Kyber.Core.emit(core, delta)
      rescue
        e ->
          Logger.error(
            "[Kyber.Tools.PromptAnnotator] failed to emit prompt.annotated: #{inspect(e)}"
          )
      end

      :ok
    end)

    Logger.info("[Kyber.Tools.PromptAnnotator] registered :annotate_prompt handler")
    :ok
  end

  # Today: a stub. Tomorrow: vault lookups, recent-delta context,
  # consolidated memories, retrieved tool docs — all merged here.
  defp build_annotations(_payload), do: %{}
end
