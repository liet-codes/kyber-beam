defmodule Kyber.Plugin.Behaviour do
  @moduledoc "Behaviour for Kyber plugins."

  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}
  @callback handle_effect(effect :: map(), state :: term()) ::
              {:ok, state :: term()} | {:error, reason :: term()}
  @callback shutdown(reason :: term(), state :: term()) :: :ok

  # Optional callbacks
  @callback capabilities() :: [atom()]
  @callback secrets() :: [atom()]

  @optional_callbacks [capabilities: 0, secrets: 0]
end
