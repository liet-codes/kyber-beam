defmodule Kyber.Memory.Condenser do
  @moduledoc """
  Memory Condenser Daemon — the **write path** for the Obsidian vault.

  Subscribes to `Kyber.Delta.Store`. When an `llm.response` delta arrives,
  it condenses the interaction into a markdown file inside the vault and
  emits a `memory.condensed` delta for provenance.

  ## V0 stub semantics

  V0 is intentionally a stub: it writes a timestamped `<ts>-<short_id>.md`
  file under `<vault>/condensed/` containing the raw response text. Future
  loops will replace this with real summarization + ADD/UPDATE/DELETE
  routing through the Knowledge graph.

  ## Why a separate process?

  The broadcast callback in `Kyber.Delta.Store` runs **inside** the Store
  GenServer. Calling `Kyber.Core.emit/2` from the callback would deadlock
  (it calls back into the same Store). The Condenser therefore receives
  deltas via `send/2` from the callback and processes them in its own
  mailbox, where it is free to perform I/O and emit follow-up deltas.
  """

  use GenServer
  require Logger

  @stub_subdir "condensed"

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    core = Keyword.get(opts, :core, Kyber.Core)
    knowledge = Keyword.get(opts, :knowledge, Kyber.Knowledge)
    store = Keyword.get(opts, :store, derived_store_name(core))

    self_pid = self()

    # Subscribe synchronously in init so callers can rely on the
    # subscription being active by the time `start_link/1` returns.
    # The callback runs inside the Store GenServer — it must not call
    # back into the Store, so we forward to ourselves and process async.
    unsubscribe_fn =
      Kyber.Delta.Store.subscribe(store, fn delta ->
        send(self_pid, {:condense, delta})
      end)

    Logger.info("[Kyber.Memory.Condenser] subscribed to #{inspect(store)}")

    {:ok,
     %{
       core: core,
       knowledge: knowledge,
       store: store,
       unsubscribe_fn: unsubscribe_fn
     }}
  end

  @impl true
  def handle_info({:condense, %Kyber.Delta{kind: "llm.response"} = delta}, state) do
    # AUDIT-HISTORY rule C2 — never perform blocking disk I/O inside a
    # GenServer callback. Check mailbox depth for backpressure, then offload
    # the actual condense (mkdir_p + write + emit) to a fire-and-forget
    # Task so handle_info returns immediately.
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if len > 100 do
      Logger.warning(
        "[Kyber.Memory.Condenser] queue full (#{len}), dropping delta #{delta.id}"
      )

      {:noreply, state}
    else
      Task.start(fn -> condense(delta, state) end)
      {:noreply, state}
    end
  end

  def handle_info({:condense, _other}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{unsubscribe_fn: unsub}) when is_function(unsub) do
    try do
      unsub.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ────────────────────────────────────────────────────────────────

  defp condense(delta, state) do
    case safe_vault_path(state.knowledge) do
      nil ->
        Logger.warning(
          "[Kyber.Memory.Condenser] no vault path available — skipping #{delta.id}"
        )

      vault_path ->
        rel_path = Path.join(@stub_subdir, condensed_filename(delta))
        abs_path = Path.join(vault_path, rel_path)
        content = render_stub(delta)

        with :ok <- File.mkdir_p(Path.dirname(abs_path)),
             :ok <- File.write(abs_path, content) do
          emit_condensed(state.core, delta, rel_path)
        else
          {:error, reason} ->
            Logger.warning(
              "[Kyber.Memory.Condenser] write failed for #{abs_path}: #{inspect(reason)}"
            )
        end
    end
  end

  defp condensed_filename(%Kyber.Delta{ts: ts, id: id}) do
    safe_id = id |> to_string() |> String.slice(0, 8)
    "#{ts}-#{safe_id}.md"
  end

  defp render_stub(delta) do
    text =
      case delta.payload do
        %{"text" => t} when is_binary(t) -> t
        %{text: t} when is_binary(t) -> t
        _ -> inspect(delta.payload)
      end

    """
    ---
    type: memory
    source_delta: #{delta.id}
    ts: #{delta.ts}
    ---

    # Condensed memory (#{delta.id})

    #{text}
    """
  end

  defp emit_condensed(core, source_delta, rel_path) do
    delta =
      Kyber.Delta.new(
        "memory.condensed",
        %{
          "source_delta_id" => source_delta.id,
          "path" => rel_path
        },
        {:system, "memory.condenser"},
        source_delta.id
      )

    try do
      Kyber.Core.emit(core, delta)
    rescue
      e ->
        Logger.error("[Kyber.Memory.Condenser] emit failed: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.error("[Kyber.Memory.Condenser] emit exited: #{inspect(reason)}")
    end
  end

  defp safe_vault_path(knowledge) do
    try do
      Kyber.Knowledge.vault_path(knowledge)
    catch
      :exit, _ -> nil
    end
  end

  defp derived_store_name(core) when is_atom(core), do: :"#{core}.Store"
  defp derived_store_name(_), do: Kyber.Delta.Store
end
