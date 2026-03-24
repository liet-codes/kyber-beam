defmodule Kyber.Config do
  @moduledoc """
  Cached configuration reads via `:persistent_term`.

  Hot-path modules should call `Kyber.Config.get/2` instead of
  `Application.get_env/3` to avoid ETS lookups on every invocation.

  Call `Kyber.Config.load!/0` at application startup (or in tests) to
  populate the cache from the current `Application` environment. Values
  can be refreshed at runtime with `reload!/0`.
  """

  @keys_with_defaults [
    {:model, "claude-sonnet-4-20250514"},
    {:llm_streaming, true},
    {:llm_thinking, true},
    {:thinking_budget_tokens, 10_000},
    {:max_context_tokens, 180_000},
    {:max_llm_calls_per_minute, 30},
    {:snap_request_path, "/tmp/snap_request"},
    {:snap_result_path, "/tmp/snap_result"},
    {:discord_token, nil},
    {:vault_path, Path.expand("~/.kyber/vault")}
  ]

  @doc "Load all known config keys from Application env into :persistent_term."
  def load! do
    for {key, default} <- @keys_with_defaults do
      val = Application.get_env(:kyber_beam, key, default)
      :persistent_term.put({__MODULE__, key}, val)
    end

    :ok
  end

  @doc "Reload config (e.g. after runtime config change)."
  def reload!, do: load!()

  @doc "Fast cached read. Falls back to Application.get_env if not yet loaded."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    try do
      :persistent_term.get({__MODULE__, key})
    rescue
      ArgumentError ->
        Application.get_env(:kyber_beam, key, default)
    end
  end
end
