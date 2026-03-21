defmodule Kyber.Web.DashboardLive do
  @moduledoc """
  Phoenix LiveView dashboard for Kyber BEAM.

  Displays real-time system state including:
  - **Overview**: uptime, node info, plugin status, delta/error counts
  - **Delta stream**: live-updating list of recent deltas
  - **Node map**: connected distribution nodes and their status

  Subscribes to the Delta.Store for live updates without requiring Phoenix.PubSub.
  Auto-refreshes state on a 5-second timer for counts/plugins/nodes.
  """

  use Phoenix.LiveView
  require Logger

  @refresh_interval_ms 5_000
  @max_displayed_deltas 50

  # ── Mount ─────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to live delta stream
      lv_pid = self()
      store = store_pid()

      Kyber.Delta.Store.subscribe(store, fn delta ->
        send(lv_pid, {:new_delta, delta})
      end)

      # Schedule periodic refresh
      Process.send_after(self(), :refresh, @refresh_interval_ms)
    end

    socket =
      socket
      |> assign(:started_at, System.system_time(:millisecond))
      |> assign(:node_name, node())
      |> assign(:expanded, MapSet.new())
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :traces}} = socket) do
    all_deltas = fetch_all_deltas()
    expanded_ids = Map.get(socket.assigns, :expanded_ids, MapSet.new())
    trace_entries = build_trace_tree(all_deltas, expanded_ids)

    socket =
      socket
      |> assign(:all_deltas, all_deltas)
      |> assign(:expanded_ids, expanded_ids)
      |> assign(:trace_entries, trace_entries)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_delta, delta}, %{assigns: %{live_action: :traces}} = socket) do
    deltas = [delta | Enum.take(socket.assigns.recent_deltas, @max_displayed_deltas - 1)]
    all_deltas = [delta | socket.assigns.all_deltas]
    expanded_ids = socket.assigns.expanded_ids
    trace_entries = build_trace_tree(all_deltas, expanded_ids)

    socket =
      socket
      |> assign(:recent_deltas, deltas)
      |> assign(:all_deltas, all_deltas)
      |> assign(:trace_entries, trace_entries)

    {:noreply, socket}
  end

  def handle_info({:new_delta, delta}, socket) do
    deltas = [delta | Enum.take(socket.assigns.recent_deltas, @max_displayed_deltas - 1)]
    {:noreply, assign(socket, :recent_deltas, deltas)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, load_state(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_delta", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded
    expanded = if MapSet.member?(expanded, id), do: MapSet.delete(expanded, id), else: MapSet.put(expanded, id)
    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("toggle_trace", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_ids

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    trace_entries = build_trace_tree(socket.assigns.all_deltas, expanded)
    {:noreply, assign(socket, expanded_ids: expanded, trace_entries: trace_entries)}
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(%{live_action: :traces} = assigns) do
    ~H"""
    <div style="padding: 16px 0;">
      <h1 style="color:#63b3ed;margin-bottom:16px;">Traces</h1>
      <p style="color:#718096;margin-bottom:16px;">Nested delta trace view — click to expand/collapse</p>
      <div style="display:flex;flex-direction:column;gap:2px;">
        <%= if @trace_entries == [] do %>
          <div style="color:#4a5568;text-align:center;padding:32px;">No traces yet…</div>
        <% end %>
        <%= for {delta, depth, has_children, expanded} <- @trace_entries do %>
          <div
            style={"padding:10px 12px;padding-left:#{12 + depth * 16}px;background:#{if depth == 0, do: "#1a1d2e", else: "#151823"};border:1px solid #{if depth == 0, do: "#2d3748", else: "#1e2435"};border-radius:6px;cursor:pointer;min-height:44px;"}
            phx-click="toggle_trace"
            phx-value-id={delta.id}
          >
            <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
              <%= if has_children do %>
                <span style="color:#4a5568;font-size:0.85rem;width:14px;"><%= if expanded, do: "▼", else: "▶" %></span>
              <% else %>
                <span style="width:14px;"></span>
              <% end %>
              <span style="font-size:1.1rem;"><%= kind_emoji(delta.kind) %></span>
              <span style="color:#68d391;font-weight:bold;font-size:0.9rem;"><%= delta.kind %></span>
              <span style="color:#718096;font-size:0.8rem;"><%= format_ts(delta.ts) %></span>
            </div>
            <%= if expanded do %>
              <div style="margin-top:8px;padding:8px;background:#0f1117;border-radius:4px;font-size:0.8rem;color:#a0aec0;white-space:pre-wrap;word-break:break-all;max-height:400px;overflow-y:auto;overflow-x:hidden;" class="json-block">
                <%= format_payload_json(delta.payload) %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render(%{live_action: :deltas} = assigns) do
    ~H"""
    <div style="padding: 16px 0;">
      <h1 style="color:#63b3ed;margin-bottom:16px;">Delta Stream</h1>
      <p style="color:#718096;margin-bottom:16px;">Live feed — newest first. Total: <%= @delta_count %></p>
      <div style="display:flex;flex-direction:column;gap:8px;">
        <%= for delta <- @recent_deltas do %>
          <div phx-click="toggle_delta" phx-value-id={delta.id}
               style={"background:#1a1d2e;border:1px solid #{delta_border_color(delta.kind)};border-radius:8px;padding:12px 14px;font-size:0.9rem;cursor:pointer;transition:border-color 0.2s;min-height:44px;"}>
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;flex-wrap:wrap;gap:4px;">
              <div style="display:flex;align-items:center;gap:8px;">
                <span style="font-size:1rem;"><%= delta_icon(delta.kind) %></span>
                <span style={"color:#{delta_kind_color(delta.kind)};font-weight:bold;font-size:0.9rem;"}><%= delta.kind %></span>
              </div>
              <span style="color:#718096;font-size:0.8rem;"><%= format_ts(delta.ts) %></span>
            </div>
            <div style="color:#a0aec0;font-size:0.8rem;overflow:hidden;text-overflow:ellipsis;">
              id: <span style="color:#63b3ed;"><%= String.slice(delta.id, 0, 12) %>…</span>
              <%= if delta.origin do %>
                <span style="color:#718096;margin-left:8px;">origin: <%= inspect_origin(delta.origin) %></span>
              <% end %>
            </div>
            <%= if MapSet.member?(@expanded, delta.id) do %>
              <div style="margin-top:12px;padding-top:12px;border-top:1px solid #2d3748;">
                <pre style="color:#e2e8f0;font-size:0.8rem;white-space:pre-wrap;word-break:break-all;max-height:400px;overflow-y:auto;"><%= Jason.encode!(delta.payload, pretty: true) %></pre>
                <%= if delta.parent_id do %>
                  <div style="color:#718096;font-size:0.75rem;margin-top:8px;">parent: <span style="color:#b794f4;"><%= delta.parent_id %></span></div>
                <% end %>
              </div>
            <% else %>
              <%= if map_size(delta.payload) > 0 do %>
                <div style="color:#4a5568;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:0.8rem;">
                  <%= delta.payload |> Map.keys() |> Enum.join(", ") %>  — tap to expand
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
        <%= if @recent_deltas == [] do %>
          <div style="color:#4a5568;text-align:center;padding:32px;">No deltas yet…</div>
        <% end %>
      </div>
    </div>
    """
  end

  def render(%{live_action: :nodes} = assigns) do
    ~H"""
    <div style="padding: 16px 0;">
      <h1 style="color:#63b3ed;margin-bottom:16px;">Node Map</h1>
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px;">
        <!-- Local node -->
        <div style="background:#1a1d2e;border:2px solid #68d391;border-radius:12px;padding:20px;">
          <div style="color:#68d391;font-weight:bold;margin-bottom:8px;">● LOCAL</div>
          <div style="color:#e2e8f0;font-size:0.9rem;"><%= @node_name %></div>
          <div style="color:#718096;font-size:0.8rem;margin-top:8px;">Uptime: <%= format_uptime(@started_at) %></div>
          <div style="color:#718096;font-size:0.8rem;">Deltas: <%= @delta_count %></div>
          <div style="color:#718096;font-size:0.8rem;">Plugins: <%= length(@plugins) %></div>
        </div>
        <!-- Remote nodes -->
        <%= for node_name <- @connected_nodes do %>
          <div style="background:#1a1d2e;border:2px solid #4299e1;border-radius:12px;padding:20px;">
            <div style="color:#4299e1;font-weight:bold;margin-bottom:8px;">◉ REMOTE</div>
            <div style="color:#e2e8f0;font-size:0.9rem;"><%= node_name %></div>
            <div style="color:#718096;font-size:0.8rem;margin-top:8px;">Connected</div>
          </div>
        <% end %>
        <%= if @connected_nodes == [] do %>
          <div style="background:#1a1d2e;border:1px dashed #2d3748;border-radius:12px;padding:20px;color:#4a5568;font-size:0.9rem;text-align:center;">
            No remote nodes connected.<br/>
            <small>Use Kyber.Distribution.connect/1 to add nodes.</small>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render(assigns) do
    # Default: :overview
    ~H"""
    <div style="padding: 16px 0;">
      <h1 style="color:#63b3ed;margin-bottom:24px;">Kyber BEAM — Overview</h1>

      <!-- Stats row -->
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:12px;margin-bottom:24px;">
        <div style={stat_card_style()}>
          <div style="color:#718096;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">Uptime</div>
          <div style="color:#68d391;font-size:1.4rem;font-weight:bold;margin-top:4px;"><%= format_uptime(@started_at) %></div>
        </div>
        <div style={stat_card_style()}>
          <div style="color:#718096;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">Total Deltas</div>
          <div style="color:#63b3ed;font-size:1.4rem;font-weight:bold;margin-top:4px;"><%= @delta_count %></div>
        </div>
        <div style={stat_card_style()}>
          <div style="color:#718096;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">Errors</div>
          <div style={error_count_style(@error_count)}><%= @error_count %></div>
        </div>
        <div style={stat_card_style()}>
          <div style="color:#718096;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">Remote Nodes</div>
          <div style="color:#b794f4;font-size:1.4rem;font-weight:bold;margin-top:4px;"><%= length(@connected_nodes) %></div>
        </div>
        <div style={stat_card_style()}>
          <div style="color:#718096;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">Active Sessions</div>
          <div style="color:#fbd38d;font-size:1.4rem;font-weight:bold;margin-top:4px;"><%= @session_count %></div>
        </div>
      </div>

      <!-- Two-column layout (stacks on mobile) -->
      <div style="display:grid;grid-template-columns:1fr;gap:16px;" class="two-col">

        <!-- Plugins -->
        <div style="background:#1a1d2e;border:1px solid #2d3748;border-radius:12px;padding:20px;">
          <h2 style="color:#a0aec0;font-size:0.9rem;text-transform:uppercase;letter-spacing:0.1em;margin-bottom:16px;">Plugins</h2>
          <%= if @plugins == [] do %>
            <div style="color:#4a5568;font-size:0.9rem;">No plugins loaded</div>
          <% else %>
            <%= for plugin <- @plugins do %>
              <div style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid #2d3748;">
                <span style="color:#68d391;">●</span>
                <span style="color:#e2e8f0;font-size:0.9rem;"><%= plugin %></span>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Recent deltas preview -->
        <div style="background:#1a1d2e;border:1px solid #2d3748;border-radius:12px;padding:20px;">
          <h2 style="color:#a0aec0;font-size:0.9rem;text-transform:uppercase;letter-spacing:0.1em;margin-bottom:16px;">Recent Deltas</h2>
          <%= for delta <- Enum.take(@recent_deltas, 8) do %>
            <div phx-click="toggle_delta" phx-value-id={delta.id}
                 style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #1e2435;font-size:0.8rem;cursor:pointer;">
              <div style="display:flex;align-items:center;gap:6px;">
                <span style="font-size:0.65rem;"><%= delta_icon(delta.kind) %></span>
                <span style={"color:#{delta_kind_color(delta.kind)};"}><%= delta.kind %></span>
              </div>
              <span style="color:#4a5568;"><%= format_ts(delta.ts) %></span>
            </div>
            <%= if MapSet.member?(@expanded, delta.id) do %>
              <div style="padding:8px 0 12px;border-bottom:1px solid #2d3748;">
                <pre style="color:#e2e8f0;font-size:0.75rem;white-space:pre-wrap;word-break:break-all;max-height:300px;overflow-y:auto;"><%= Jason.encode!(delta.payload, pretty: true) %></pre>
              </div>
            <% end %>
          <% end %>
          <%= if @recent_deltas == [] do %>
            <div style="color:#4a5568;font-size:0.9rem;">No deltas yet</div>
          <% end %>
          <%= if length(@recent_deltas) > 0 do %>
            <div style="margin-top:12px;">
              <a href="/dashboard/deltas" style="color:#63b3ed;font-size:0.8rem;">View all →</a>
            </div>
          <% end %>
        </div>

      </div>

      <!-- Node info -->
      <div style="background:#1a1d2e;border:1px solid #2d3748;border-radius:12px;padding:20px;margin-top:24px;">
        <h2 style="color:#a0aec0;font-size:0.9rem;text-transform:uppercase;letter-spacing:0.1em;margin-bottom:12px;">Current Node</h2>
        <div style="color:#e2e8f0;font-size:0.9rem;"><strong style="color:#718096;">Name:</strong> <%= @node_name %></div>
        <div style="color:#e2e8f0;font-size:0.9rem;margin-top:4px;"><strong style="color:#718096;">OTP:</strong> <%= :erlang.system_info(:otp_release) %></div>
        <div style="color:#e2e8f0;font-size:0.9rem;margin-top:4px;"><strong style="color:#718096;">Processes:</strong> <%= :erlang.system_info(:process_count) %></div>
      </div>
    </div>
    """
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp load_state(socket) do
    {delta_count, recent_deltas} = fetch_deltas()
    kyber_state = safe_get_state()
    connected_nodes = safe_get_nodes()

    socket
    |> assign(:delta_count, delta_count)
    |> assign(:recent_deltas, recent_deltas)
    |> assign(:plugins, kyber_state.plugins)
    |> assign(:error_count, length(kyber_state.errors))
    |> assign(:session_count, map_size(kyber_state.sessions))
    |> assign(:connected_nodes, connected_nodes)
  end

  defp fetch_deltas do
    store = store_pid()

    deltas =
      try do
        Kyber.Delta.Store.query(store)
      rescue
        _ -> []
      end

    recent = deltas |> Enum.reverse() |> Enum.take(@max_displayed_deltas)
    {length(deltas), recent}
  end

  defp safe_get_state do
    # Gather state from actual running GenServers
    # Detect running plugins by checking known GenServer names
    plugin_checks = [
      {"Discord", Kyber.Plugin.Discord},
      {"LLM", Kyber.Plugin.LLM},
      {"Knowledge", Kyber.Knowledge},
      {"Cron", Kyber.Cron},
      {"Delta.Store", Kyber.Delta.Store}
    ]

    plugins =
      Enum.filter(plugin_checks, fn {_name, mod} ->
        Process.whereis(mod) != nil
      end)
      |> Enum.map(fn {name, _} -> name end)

    sessions =
      try do
        # ETS table :kyber_sessions
        case :ets.info(:kyber_sessions) do
          :undefined -> %{}
          _ -> :ets.tab2list(:kyber_sessions) |> Map.new()
        end
      rescue
        _ -> %{}
      end

    cron_jobs =
      try do
        Kyber.Cron.list_jobs()
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    %{plugins: plugins, errors: [], sessions: sessions, cron_jobs: cron_jobs}
  end

  defp safe_get_nodes do
    Node.list()
  end

  defp store_pid do
    Process.get(:kyber_store_pid) || :"Elixir.Kyber.Core.Store"
  end

  defp format_ts(ts) when is_integer(ts) do
    seconds = div(ts, 1000)
    now = System.system_time(:second)
    diff = now - seconds

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp format_ts(_), do: "unknown"

  defp format_uptime(started_at) do
    now = System.system_time(:millisecond)
    diff_s = div(now - started_at, 1000)

    cond do
      diff_s < 60 -> "#{diff_s}s"
      diff_s < 3600 -> "#{div(diff_s, 60)}m #{rem(diff_s, 60)}s"
      true -> "#{div(diff_s, 3600)}h #{rem(div(diff_s, 60), 60)}m"
    end
  end

  defp delta_icon(kind) do
    case kind do
      "message.received" -> "💬"
      "llm.response" -> "🧠"
      "llm.call" -> "🤖"
      "tool.call" -> "🔧"
      "tool.result" -> "📋"
      "tool_use" -> "🔧"
      "cron.fired" -> "⏰"
      "send_message" -> "📤"
      "session." <> _ -> "📋"
      "error" <> _ -> "❌"
      _ -> "◆"
    end
  end

  defp delta_kind_color(kind) do
    case kind do
      "message.received" -> "#68d391"
      "llm.response" -> "#63b3ed"
      "llm.call" -> "#9ae6b4"
      "tool.call" -> "#fbd38d"
      "tool.result" -> "#f6e05e"
      "tool_use" -> "#fbd38d"
      "cron.fired" -> "#b794f4"
      "send_message" -> "#4fd1c5"
      "error" <> _ -> "#fc8181"
      _ -> "#a0aec0"
    end
  end

  defp delta_border_color(kind) do
    case kind do
      "error" <> _ -> "#fc8181"
      _ -> "#2d3748"
    end
  end

  defp inspect_origin(origin) when is_map(origin) do
    cond do
      origin["chat_id"] -> "chat:#{origin["chat_id"]}"
      origin["type"] -> origin["type"]
      true -> inspect(origin)
    end
  end

  defp inspect_origin(origin) when is_tuple(origin) do
    case origin do
      {:channel, "discord", cid, _} -> "discord:#{cid}"
      {:cron, name} -> "cron:#{name}"
      _ -> inspect(origin)
    end
  end

  defp inspect_origin(origin), do: inspect(origin)

  # ── Trace helpers ─────────────────────────────────────────────────────

  defp fetch_all_deltas do
    store = store_pid()

    try do
      Kyber.Delta.Store.query(store)
    rescue
      _ -> []
    end
  end

  defp build_trace_tree(deltas, expanded_ids) do
    by_parent = Enum.group_by(deltas, & &1.parent_id)
    all_ids = MapSet.new(deltas, & &1.id)

    roots =
      deltas
      |> Enum.filter(fn d ->
        is_nil(d.parent_id) or not MapSet.member?(all_ids, d.parent_id)
      end)
      |> Enum.sort_by(& &1.ts, :desc)

    flatten_trace(roots, by_parent, expanded_ids, 0)
  end

  defp flatten_trace(nodes, by_parent, expanded_ids, depth) do
    Enum.flat_map(nodes, fn node ->
      children = Map.get(by_parent, node.id, []) |> Enum.sort_by(& &1.ts)
      has_children = children != []
      expanded = MapSet.member?(expanded_ids, node.id)
      entry = {node, depth, has_children, expanded}

      if expanded and has_children do
        [entry | flatten_trace(children, by_parent, expanded_ids, depth + 1)]
      else
        [entry]
      end
    end)
  end

  defp kind_emoji("message.received"), do: "📨"
  defp kind_emoji("llm.call"), do: "🤖"
  defp kind_emoji("llm.response"), do: "💬"
  defp kind_emoji("llm.error"), do: "❌"
  defp kind_emoji("tool.call"), do: "🔧"
  defp kind_emoji("tool.result"), do: "📋"
  defp kind_emoji("plugin.loaded"), do: "🔌"
  defp kind_emoji("cron.fired"), do: "⏰"
  defp kind_emoji(_), do: "📌"

  defp payload_preview(payload) when map_size(payload) == 0, do: ""

  defp payload_preview(payload) do
    str = inspect(payload, limit: 3, printable_limit: 80)

    if String.length(str) > 100 do
      String.slice(str, 0, 100) <> "…"
    else
      str
    end
  end

  defp format_payload_json(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(payload, pretty: true)
    end
  end

  defp stat_card_style do
    "background:#1a1d2e;border:1px solid #2d3748;border-radius:12px;padding:16px;"
  end

  defp error_count_style(count) when count > 0 do
    "color:#fc8181;font-size:1.4rem;font-weight:bold;margin-top:4px;"
  end

  defp error_count_style(_) do
    "color:#68d391;font-size:1.4rem;font-weight:bold;margin-top:4px;"
  end
end
