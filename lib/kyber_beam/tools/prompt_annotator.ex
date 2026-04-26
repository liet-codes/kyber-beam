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
    knowledge = Map.get(effect, :knowledge)

    annotated_payload =
      payload
      |> Map.put("annotations", build_annotations(payload, knowledge))
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

  # Stage 1 of the Two-Stage RAG: lightweight L0 surfacing.
  #
  # When a `Kyber.Knowledge` server is wired into the effect, scan its
  # vault for notes whose titles appear in the prompt text and embed
  # an L0 view (title / type / tags) of each match into the annotations
  # under `"l0"`. Stage 2 (deep L1/L2 retrieval via a `vault_search`
  # tool) is the LLM's job and lives elsewhere.
  defp build_annotations(_payload, nil), do: %{}

  defp build_annotations(payload, knowledge) do
    text = payload |> Map.get("text", "") |> to_string()
    %{"l0" => surface_l0(knowledge, text)}
  end

  defp surface_l0(_knowledge, ""), do: []

  defp surface_l0(knowledge, text) do
    text_lower = String.downcase(text)

    knowledge
    |> Kyber.Knowledge.query_notes([])
    |> Enum.filter(&title_matches?(&1, text_lower))
    |> Enum.map(&note_to_l0/1)
  rescue
    e ->
      Logger.warning("[Kyber.Tools.PromptAnnotator] L0 surfacing failed: #{inspect(e)}")
      []
  end

  defp title_matches?(note, text_lower) do
    case Map.get(note.frontmatter, "title") do
      title when is_binary(title) and title != "" ->
        String.contains?(text_lower, String.downcase(title))

      _ ->
        false
    end
  end

  defp note_to_l0(note) do
    fm = note.frontmatter

    %{
      "title" => Map.get(fm, "title"),
      "type" => Map.get(fm, "type"),
      "tags" => Map.get(fm, "tags", [])
    }
  end
end
