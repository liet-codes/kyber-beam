defmodule Kyber.Introspection do
  @moduledoc """
  BEAM runtime introspection for Stilgar.

  Wraps :erlang BIFs and OTP inspection functions into clean maps
  suitable for tool results. All functions return plain data (no PIDs,
  no atoms in values) so results serialize cleanly to JSON strings.

  This is what separates kyber-beam from every Node.js-based agent:
  Stilgar can look at his own guts.
  """

  require Logger

  @doc """
  System-level memory breakdown in MB.

  Returns total, processes, system, atom, binary, code, ets.
  """
  def memory_summary do
    mem = :erlang.memory()

    %{
      total_mb: to_mb(mem[:total]),
      processes_mb: to_mb(mem[:processes]),
      system_mb: to_mb(mem[:system]),
      atom_mb: to_mb(mem[:atom]),
      binary_mb: to_mb(mem[:binary]),
      ets_mb: to_mb(mem[:ets]),
      code_mb: to_mb(mem[:code])
    }
  end

  @doc """
  System info summary: schedulers, uptime, process/port/atom counts.
  """
  def system_info do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      uptime_seconds: div(uptime_ms, 1000),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts_version: to_string(:erlang.system_info(:version))
    }
  end

  @doc """
  Top N processes by memory usage.
  Returns pid-string, name, memory_kb, message_queue_len, reductions, current_function.
  """
  def top_processes(n \\ 20) do
    :erlang.processes()
    |> Enum.map(fn pid ->
      info =
        Process.info(pid, [
          :registered_name,
          :memory,
          :message_queue_len,
          :reductions,
          :current_function
        ])

      if info do
        name =
          case info[:registered_name] do
            [] -> inspect(pid)
            name -> to_string(name)
          end

        {cf_m, cf_f, cf_a} = info[:current_function] || {:unknown, :unknown, 0}

        %{
          pid: inspect(pid),
          name: name,
          memory_kb: to_kb(info[:memory]),
          message_queue_len: info[:message_queue_len],
          reductions: info[:reductions],
          current_function: "#{cf_m}.#{cf_f}/#{cf_a}"
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_kb, :desc)
    |> Enum.take(n)
  end

  @doc """
  Inspect a named process: memory, queue length, status, current function, links.
  """
  def inspect_process(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, "Process #{name} not found"}
      pid -> inspect_pid(pid)
    end
  end

  @doc false
  def inspect_pid(pid) when is_pid(pid) do
    keys = [
      :registered_name,
      :memory,
      :message_queue_len,
      :reductions,
      :status,
      :current_function,
      :links,
      :trap_exit,
      :heap_size
    ]

    case Process.info(pid, keys) do
      nil ->
        {:error, "Process #{inspect(pid)} not alive"}

      info ->
        {cf_m, cf_f, cf_a} = info[:current_function] || {:unknown, :unknown, 0}

        %{
          pid: inspect(pid),
          name:
            case info[:registered_name] do
              [] -> nil
              n -> to_string(n)
            end,
          memory_kb: to_kb(info[:memory]),
          message_queue_len: info[:message_queue_len],
          reductions: info[:reductions],
          status: to_string(info[:status]),
          current_function: "#{cf_m}.#{cf_f}/#{cf_a}",
          link_count: length(info[:links] || []),
          trap_exit: info[:trap_exit],
          heap_size_words: info[:heap_size]
        }
    end
  end

  @doc """
  Get GenServer internal state via :sys.get_state/1.

  Works on any named GenServer. Returns the state as an inspected string
  (not all states are JSON-safe, so inspect is safer than Jason.encode).
  Truncated to 10KB.
  """
  def genserver_state(name) when is_atom(name) do
    try do
      state = :sys.get_state(name, 5_000)
      full = inspect(state, limit: 50, pretty: true)
      {:ok, String.slice(full, 0, 10_240)}
    catch
      :exit, {:timeout, _} -> {:error, "timeout — process may be busy"}
      :exit, {:noproc, _} -> {:error, "process #{name} not running"}
      :exit, reason -> {:error, "exit: #{inspect(reason)}"}
    end
  end

  @doc """
  Walk a supervisor's children. Returns name, pid-or-status, type, module.
  Optionally recurse into child supervisors (depth default 2).
  """
  def supervision_tree(supervisor, depth \\ 2) do
    try do
      children = Supervisor.which_children(supervisor)
      counts = Supervisor.count_children(supervisor)

      %{
        supervisor: to_string(supervisor),
        counts: %{
          active: counts.active,
          workers: counts.workers,
          supervisors: counts.supervisors,
          specs: counts.specs
        },
        children:
          Enum.map(children, fn {id, pid_or_status, type, mods} ->
            child = %{
              id: inspect(id),
              type: to_string(type),
              module: inspect(List.first(mods) || :unknown),
              status: inspect(pid_or_status)
            }

            if depth > 1 && type == :supervisor && is_pid(pid_or_status) do
              Map.put(child, :children, supervision_tree(pid_or_status, depth - 1))
            else
              child
            end
          end)
      }
    catch
      :exit, _ -> {:error, "#{supervisor} not running or not a supervisor"}
    end
  end

  @doc """
  ETS table summary: all tables with name, size, memory, type.
  """
  def ets_tables do
    :ets.all()
    |> Enum.map(fn table ->
      try do
        info = :ets.info(table)

        %{
          id: inspect(table),
          name: to_string(info[:name]),
          size: info[:size],
          memory_kb: to_kb(info[:memory] * :erlang.system_info(:wordsize)),
          type: to_string(info[:type]),
          owner: inspect(info[:owner])
        }
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_kb, :desc)
  end

  @doc """
  Inspect a specific ETS table: size, memory, sample of keys.
  """
  def ets_inspect(table_name) when is_atom(table_name) do
    try do
      info = :ets.info(table_name)

      sample_keys =
        :ets.tab2list(table_name)
        |> Enum.take(5)
        |> Enum.map(fn
          {k, _v} -> inspect(k)
          other -> inspect(other)
        end)

      %{
        name: to_string(info[:name]),
        size: info[:size],
        memory_kb: to_kb(info[:memory] * :erlang.system_info(:wordsize)),
        type: to_string(info[:type]),
        sample_keys: sample_keys
      }
    rescue
      _ -> {:error, "Table #{table_name} not found or not accessible"}
    end
  end

  @doc """
  Delta store stats: total deltas, breakdown by kind, file size.
  """
  def delta_store_stats do
    store = Kyber.Core.Store

    try do
      all_deltas = Kyber.Delta.Store.query(store, [])

      by_kind =
        all_deltas
        |> Enum.group_by(& &1.kind)
        |> Enum.map(fn {kind, deltas} -> {to_string(kind), length(deltas)} end)
        |> Enum.sort_by(fn {_, count} -> count end, :desc)
        |> Map.new()

      store_path =
        Path.join(System.get_env("KYBER_DATA_DIR", "priv/data"), "deltas.jsonl")

      file_size_kb =
        case File.stat(store_path) do
          {:ok, %{size: size}} -> to_kb(size)
          _ -> nil
        end

      %{
        total_deltas: length(all_deltas),
        by_kind: by_kind,
        file_size_kb: file_size_kb,
        store_path: store_path
      }
    catch
      _, _ -> {:error, "Delta store not accessible"}
    end
  end

  @doc """
  Processes with message queues at or over the threshold.
  Useful for detecting backpressure. Default threshold: 5.
  """
  def queue_health(threshold \\ 5) do
    :erlang.processes()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :message_queue_len]) do
        nil ->
          []

        info ->
          if info[:message_queue_len] >= threshold do
            name =
              case info[:registered_name] do
                [] -> inspect(pid)
                n -> to_string(n)
              end

            [%{pid: inspect(pid), name: name, queue_len: info[:message_queue_len]}]
          else
            []
          end
      end
    end)
    |> Enum.sort_by(& &1.queue_len, :desc)
  end

  @doc """
  Trigger GC on a named process. Returns memory before/after/freed.
  Pass :all to GC every process.
  """
  def gc_process(name) when is_atom(name) and name != :all do
    case Process.whereis(name) do
      nil ->
        {:error, "Process #{name} not found"}

      pid ->
        before_mem = case Process.info(pid, :memory) do
          {:memory, val} -> val
          nil -> 0
        end
        :erlang.garbage_collect(pid)
        after_mem = case Process.info(pid, :memory) do
          {:memory, val} -> val
          nil -> 0
        end

        %{
          process: to_string(name),
          before_kb: to_kb(before_mem),
          after_kb: to_kb(after_mem),
          freed_kb: to_kb(max(before_mem - after_mem, 0))
        }
    end
  end

  def gc_process(:all) do
    before_total = :erlang.memory(:total)
    :erlang.processes() |> Enum.each(&:erlang.garbage_collect/1)
    after_total = :erlang.memory(:total)

    %{
      scope: "all_processes",
      before_mb: to_mb(before_total),
      after_mb: to_mb(after_total),
      freed_mb: to_mb(max(before_total - after_total, 0))
    }
  end

  @doc """
  I/O stats: bytes in/out since VM start.
  """
  def io_stats do
    {{:input, bytes_in}, {:output, bytes_out}} = :erlang.statistics(:io)

    %{
      input_mb: to_mb(bytes_in),
      output_mb: to_mb(bytes_out)
    }
  end

  @doc """
  Port summary: total count and details on a sample of active ports.
  """
  def port_info do
    ports = Port.list()

    details =
      ports
      |> Enum.take(20)
      |> Enum.map(fn port ->
        info = Port.info(port)

        %{
          port: inspect(port),
          name: to_string(info[:name] || ""),
          connected: inspect(info[:connected]),
          links: length(info[:links] || [])
        }
      end)

    %{total_ports: length(ports), sample: details}
  end

  @doc """
  Hot-reload a module. Logs a warning and returns result.
  """
  def reload_module(module_name) when is_atom(module_name) do
    Logger.warning("[Kyber.Introspection] Hot reloading module: #{module_name}")

    case Code.ensure_loaded(module_name) do
      {:module, _} ->
        try do
          case :code.purge(module_name) do
            _ ->
              case :code.load_file(module_name) do
                {:module, ^module_name} ->
                  {:ok, "#{module_name} reloaded successfully"}

                {:error, reason} ->
                  {:error, "load failed: #{inspect(reason)}"}
              end
          end
        rescue
          e -> {:error, "reload failed: #{inspect(e)}"}
        end

      {:error, reason} ->
        {:error, "module not found: #{inspect(reason)}"}
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp to_mb(bytes) when is_integer(bytes), do: round(bytes / 1_048_576 * 100) / 100
  defp to_mb(_), do: 0.0

  defp to_kb(bytes) when is_integer(bytes), do: round(bytes / 1024 * 10) / 10
  defp to_kb(_), do: 0.0
end
