ExUnit.start(exclude: [:pending])

defmodule TestHelpers do
  @moduledoc """
  Shared test utilities. Use `import TestHelpers` in tests that need `eventually/1,2`.
  """

  @doc """
  Polls `fun` until it returns without raising, up to `timeout` ms.
  Falls through and re-raises the last error if the deadline is exceeded.
  """
  def eventually(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, interval, deadline)
  end

  defp do_eventually(fun, interval, deadline) do
    try do
      fun.()
    rescue
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          do_eventually(fun, interval, deadline)
        else
          fun.()  # Let it fail with the real error
        end
    end
  end
end
