defmodule Kyber.Web.Server do
  @moduledoc "Starts the Bandit HTTP server serving Kyber.Web.Router."

  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4000)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [port]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(port) do
    Bandit.start_link(plug: Kyber.Web.Router, port: port)
  end
end
