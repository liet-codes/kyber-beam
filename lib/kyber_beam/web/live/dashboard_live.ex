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

  alias Kyber.Web.ImageDetector

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
      |> assign(:raw_visible, MapSet.new())
      |> assign(:image_modal, nil)
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

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_raw", %{"id" => id}, socket) do
    raw_visible = socket.assigns.raw_visible

    raw_visible =
      if MapSet.member?(raw_visible, id),
        do: MapSet.delete(raw_visible, id),
        else: MapSet.put(raw_visible, id)

    {:noreply, assign(socket, :raw_visible, raw_visible)}
  end

  def handle_event("show_image", %{"delta-id" => delta_id, "index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    # Find the delta and extract its images
    delta = find_delta(socket, delta_id)
    images = if delta, do: ImageDetector.extract_images(delta.payload), else: []

    case Enum.at(images, idx) do
      {label, media_type, base64} ->
        {:noreply, assign(socket, :image_modal, %{label: label, media_type: media_type, base64: base64})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply, assign(socket, :image_modal, nil)}
  end

  def handle_event("toggle_trace", %{"id" => id}, socket) do
    require Logger
    Logger.info("[Dashboard] toggle_trace id=#{id}")
    expanded = socket.assigns.expanded_ids

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    Logger.info("[Dashboard] expanded_ids now has #{MapSet.size(expanded)} entries")
    trace_entries = build_trace_tree(socket.assigns.all_deltas, expanded)
    Logger.info("[Dashboard] trace_entries count: #{length(trace_entries)}")
    {:noreply, assign(socket, expanded_ids: expanded, trace_entries: trace_entries)}
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(%{live_action: :traces} = assigns) do
    trace_groups = group_trace_entries(assigns.trace_entries)
    assigns = assign(assigns, :trace_groups, trace_groups)

    ~H"""
    <div style="padding: 16px 0;">
      <h1 style="color:#63b3ed;margin-bottom:16px;">Traces</h1>
      <p style="color:#718096;margin-bottom:16px;">Nested delta trace view — click to expand/collapse</p>
      <div style="display:flex;flex-direction:column;gap:12px;">
        <%= if @trace_groups == [] do %>
          <div style="color:#4a5568;text-align:center;padding:32px;">No traces yet…</div>
        <% end %>
        <%= for {root, children} <- @trace_groups do %>
          <% {root_delta, _depth, root_has_children, root_expanded} = root %>
          <% root_images = ImageDetector.extract_images(root_delta.payload) %>
          <%!-- Outer card wraps root + waterfall + all children --%>
          <div class="trace-root" style="background:#1a1d2e;border:1px solid #2d3748;border-radius:8px;overflow:hidden;">
            <%!-- Root header (clickable) --%>
            <div
              role="button"
              tabindex="0"
              style="padding:12px;cursor:pointer;-webkit-tap-highlight-color:rgba(99,179,237,0.3);"
              phx-click="toggle_trace"
              phx-value-id={root_delta.id}
            >
              <div class="trace-header">
                <%= if root_has_children do %>
                  <span class="trace-toggle"><%= if root_expanded, do: "▼", else: "▶" %></span>
                <% else %>
                  <span class="trace-toggle-spacer"></span>
                <% end %>
                <span class="trace-kind" style={"color:#{delta_kind_color(root_delta.kind)};"}><%= root_delta.kind %></span>
                <%= if root_images != [] do %>
                  <span title={"#{length(root_images)} image(s)"} style="margin-left:4px;">🖼️</span>
                <% end %>
                <span class="trace-ts"><%= format_ts(root_delta.ts) %></span>
              </div>
              <div class="trace-summary">
                <%= Phoenix.HTML.raw(delta_summary_html(root_delta)) %>
              </div>
              <%= if token_badge(root_delta) do %>
                <div class="trace-tokens"><%= token_badge(root_delta) %></div>
              <% end %>
            </div>

            <%!-- Expanded content: waterfall + children, all inside the card --%>
            <%= if root_expanded do %>
              <%!-- Waterfall + token summary --%>
              <% waterfall = build_waterfall(@all_deltas, root_delta.id, root_delta.ts) %>
              <% token_summary = trace_token_summary(@all_deltas, root_delta.id) %>
              <div style="padding:0 12px 8px;border-top:1px solid #2d3748;">
                <%= if token_summary do %>
                  <div class="trace-token-summary" style="margin-top:8px;"><%= token_summary %></div>
                <% end %>
                <div class="wf-legend" style="margin-top:8px;">
                  <div class="wf-legend-item">
                    <div class="wf-legend-swatch" style="background:#68d391;"></div>
                    External input
                  </div>
                  <div class="wf-legend-item">
                    <div class="wf-legend-swatch" style="background:#63b3ed;"></div>
                    Remote service
                  </div>
                  <div class="wf-legend-item">
                    <div class="wf-legend-swatch" style="background:#fbd38d;"></div>
                    Internal operation
                  </div>
                </div>
                <div class="waterfall-container">
                  <%= for bar <- waterfall do %>
                    <div class="wf-row">
                      <div class="wf-label" title={bar.label}><%= bar.label %></div>
                      <div class="wf-track">
                        <div
                          class="wf-bar"
                          style={"left:#{bar.offset_pct}%;width:#{bar.width_pct}%;background:#{waterfall_color(bar.category)};"}
                        >
                          <span class="wf-ms"><%= bar.duration_ms %>ms</span>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Root images --%>
              <%= if root_images != [] do %>
                <div style="padding:0 12px 8px;display:flex;flex-wrap:wrap;gap:8px;" phx-click="noop">
                  <%= for {{label, media_type, base64}, idx} <- Enum.with_index(root_images) do %>
                    <div style="display:flex;flex-direction:column;align-items:center;gap:4px;">
                      <div
                        phx-click="show_image"
                        phx-value-delta-id={root_delta.id}
                        phx-value-index={idx}
                        style="cursor:zoom-in;border:1px solid #4a5568;border-radius:6px;overflow:hidden;background:#0d1117;"
                      >
                        <img
                          src={"data:#{media_type};base64,#{base64}"}
                          style="max-width:300px;max-height:200px;display:block;"
                          loading="lazy"
                          onerror="this.style.display='none';this.nextElementSibling.style.display='flex';"
                        />
                        <div style="display:none;width:300px;height:100px;align-items:center;justify-content:center;color:#fc8181;font-size:0.8rem;">
                          ⚠️ Broken image
                        </div>
                      </div>
                      <span style="color:#a0aec0;font-size:0.7rem;"><%= label %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Child deltas (inside the card) --%>
              <%= for {child_delta, child_depth, child_has_children, child_expanded} <- children do %>
                <% child_images = ImageDetector.extract_images(child_delta.payload) %>
                <div
                  role="button"
                  tabindex="0"
                  class="trace-child"
                  style={"padding:8px 12px;padding-left:#{12 + child_depth * 20}px;cursor:pointer;border-top:1px solid #1e2435;-webkit-tap-highlight-color:rgba(99,179,237,0.3);"}
                  phx-click="toggle_trace"
                  phx-value-id={child_delta.id}
                >
                  <div class="trace-header">
                    <%= if child_has_children do %>
                      <span class="trace-toggle"><%= if child_expanded, do: "▼", else: "▶" %></span>
                    <% else %>
                      <span class="trace-toggle-spacer"></span>
                    <% end %>
                    <span class="trace-kind" style={"color:#{delta_kind_color(child_delta.kind)};"}><%= child_delta.kind %></span>
                    <%= if child_images != [] do %>
                      <span title={"#{length(child_images)} image(s)"} style="margin-left:4px;">🖼️</span>
                    <% end %>
                    <span class="trace-ts"><%= format_ts(child_delta.ts) %></span>
                  </div>
                  <div class="trace-summary">
                    <%= Phoenix.HTML.raw(delta_summary_html(child_delta)) %>
                  </div>
                  <%= if token_badge(child_delta) do %>
                    <div class="trace-tokens"><%= token_badge(child_delta) %></div>
                  <% end %>
                  <%= if child_expanded and child_delta.kind == "llm.stream_chunk" do %>
                    <% stream_text = child_delta.payload["text"] || "" %>
                    <%= if stream_text != "" do %>
                      <div style="margin-top:8px;padding:8px;background:#0d1117;border-radius:4px;max-height:300px;overflow-y:auto;font-size:0.8rem;color:#e2e8f0;white-space:pre-wrap;word-break:break-word;">
                        <%= stream_text %>
                      </div>
                    <% end %>
                  <% end %>
                  <%= if child_expanded and child_images != [] do %>
                    <div style="margin-top:8px;display:flex;flex-wrap:wrap;gap:8px;" phx-click="noop">
                      <%= for {{label, media_type, base64}, idx} <- Enum.with_index(child_images) do %>
                        <div style="display:flex;flex-direction:column;align-items:center;gap:4px;">
                          <div
                            phx-click="show_image"
                            phx-value-delta-id={child_delta.id}
                            phx-value-index={idx}
                            style="cursor:zoom-in;border:1px solid #4a5568;border-radius:6px;overflow:hidden;background:#0d1117;"
                          >
                            <img
                              src={"data:#{media_type};base64,#{base64}"}
                              style="max-width:300px;max-height:200px;display:block;"
                              loading="lazy"
                              onerror="this.style.display='none';this.nextElementSibling.style.display='flex';"
                            />
                            <div style="display:none;width:300px;height:100px;align-items:center;justify-content:center;color:#fc8181;font-size:0.8rem;">
                              ⚠️ Broken image
                            </div>
                          </div>
                          <span style="color:#a0aec0;font-size:0.7rem;"><%= label %></span>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
      <.image_modal image_modal={@image_modal} />
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
            <% delta_imgs = ImageDetector.extract_images(delta.payload) %>
            <%= if MapSet.member?(@expanded, delta.id) do %>
              <div style="margin-top:12px;padding-top:12px;border-top:1px solid #2d3748;">
                <%!-- Inline images --%>
                <%= if delta_imgs != [] do %>
                  <div style="margin-bottom:12px;display:flex;flex-wrap:wrap;gap:8px;">
                    <%= for {{label, media_type, base64}, idx} <- Enum.with_index(delta_imgs) do %>
                      <div style="display:flex;flex-direction:column;align-items:center;gap:4px;">
                        <div
                          phx-click="show_image"
                          phx-value-delta-id={delta.id}
                          phx-value-index={idx}
                          style="cursor:zoom-in;border:1px solid #4a5568;border-radius:6px;overflow:hidden;background:#0d1117;"
                        >
                          <img
                            src={"data:#{media_type};base64,#{base64}"}
                            style="max-width:300px;max-height:200px;display:block;"
                            loading="lazy"
                            onerror="this.style.display='none';this.nextElementSibling.style.display='flex';"
                          />
                          <div style="display:none;width:300px;height:100px;align-items:center;justify-content:center;color:#fc8181;font-size:0.8rem;">
                            ⚠️ Broken image
                          </div>
                        </div>
                        <span style="color:#a0aec0;font-size:0.7rem;"><%= label %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <%!-- Structured payload card --%>
                <.render_payload_card delta={delta} raw_visible={@raw_visible} />
                <%= if delta.parent_id do %>
                  <div style="color:#718096;font-size:0.75rem;margin-top:8px;">parent: <span style="color:#b794f4;"><%= delta.parent_id %></span></div>
                <% end %>
              </div>
            <% else %>
              <%= if map_size(delta.payload) > 0 do %>
                <div style="color:#4a5568;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:0.8rem;">
                  <%= delta.payload |> Map.keys() |> Enum.join(", ") %>
                  <%= if delta_imgs != [] do %>
                    <span style="margin-left:4px;">🖼️ <%= length(delta_imgs) %> image(s)</span>
                  <% end %>
                  — tap to expand
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
        <%= if @recent_deltas == [] do %>
          <div style="color:#4a5568;text-align:center;padding:32px;">No deltas yet…</div>
        <% end %>
      </div>
      <.image_modal image_modal={@image_modal} />
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
              <% overview_imgs = ImageDetector.extract_images(delta.payload) %>
              <div style="padding:8px 0 12px;border-bottom:1px solid #2d3748;">
                <%= if overview_imgs != [] do %>
                  <div style="margin-bottom:8px;display:flex;flex-wrap:wrap;gap:6px;">
                    <%= for {{label, media_type, base64}, idx} <- Enum.with_index(overview_imgs) do %>
                      <div
                        phx-click="show_image"
                        phx-value-delta-id={delta.id}
                        phx-value-index={idx}
                        style="cursor:zoom-in;border:1px solid #4a5568;border-radius:4px;overflow:hidden;"
                      >
                        <img src={"data:#{media_type};base64,#{base64}"} style="max-width:200px;max-height:120px;display:block;" loading="lazy" title={label} />
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <.render_payload_card delta={delta} raw_visible={@raw_visible} />
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

  defp find_delta(socket, delta_id) do
    all = Map.get(socket.assigns, :all_deltas, []) ++ Map.get(socket.assigns, :recent_deltas, [])
    Enum.find(all, &(&1.id == delta_id))
  end

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
      "llm.stream_chunk" -> "💬"
      "llm.call" -> "🤖"
      "tool.call" -> "🔧"
      "tool.result" -> "📋"
      "tool_use" -> "🔧"
      "cron.fired" -> "⏰"
      "send_message" -> "📤"
      "plugin.loaded" -> "🔌"
      "plugin.unloaded" -> "🔌"
      "session." <> _ -> "📋"
      "error" <> _ -> "❌"
      _ -> "◆"
    end
  end

  defp delta_kind_color(kind) do
    case kind do
      "message.received" -> "#68d391"
      "llm.response" -> "#63b3ed"
      "llm.stream_chunk" -> "#76e4f7"
      "llm.call" -> "#9ae6b4"
      "tool.call" -> "#fbd38d"
      "tool.result" -> "#f6e05e"
      "tool_use" -> "#fbd38d"
      "cron.fired" -> "#b794f4"
      "send_message" -> "#4fd1c5"
      "plugin.loaded" -> "#68d391"
      "plugin.unloaded" -> "#718096"
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

  # Groups flat trace entries into [{root_entry, [child_entries]}, ...]
  defp group_trace_entries(entries) do
    entries
    |> Enum.chunk_while(
      [],
      fn
        {_, 0, _, _} = entry, [] ->
          {:cont, [entry]}

        {_, 0, _, _} = entry, acc ->
          {:cont, Enum.reverse(acc), [entry]}

        entry, acc ->
          {:cont, [entry | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn
      [root | children] -> {root, children}
      [] -> nil
    end)
    |> Enum.reject(&is_nil/1)
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
  defp kind_emoji("familiard.escalation"), do: "⚠️"
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


  # ── Known entity maps ──────────────────────────────────────────────────

  @known_users %{
    "353690689571258376" => "mykola_b"
  }

  @known_guilds %{
    "1483371179459870834" => "Arrakis"
  }

  @known_channels %{
    "1483371179459870834" => "#general"
  }

  defp resolve_user(id), do: Map.get(@known_users, to_string(id), to_string(id))
  defp resolve_guild(id), do: Map.get(@known_guilds, to_string(id), to_string(id))
  defp resolve_channel(id), do: Map.get(@known_channels, to_string(id), "#" <> to_string(id))

  # ── Rich delta summaries ───────────────────────────────────────────────

  defp delta_summary(%{kind: "message.received", payload: p}) do
    user = resolve_user(p["author_id"] || p["username"] || "?")
    channel = resolve_channel(p["channel_id"])
    guild = if p["guild_id"], do: " (#{resolve_guild(p["guild_id"])})", else: ""
    text = p["text"] || ""
    truncated = if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
    "💬 **#{user}** in #{channel}#{guild}: \"#{truncated}\""
  end

  defp delta_summary(%{kind: "llm.call", payload: p}) do
    model = p["model"] || "unknown"
    msgs = p["message_count"] || "?"
    tools = if is_list(p["tools"]), do: length(p["tools"]), else: p["tools"] || 0
    "🤖 Calling #{model} with #{msgs} messages, #{tools} tools available"
  end

  defp delta_summary(%{kind: "llm.response", payload: p}) do
    usage = p["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    cache = usage["cache_read_input_tokens"] || 0
    content = p["content"] || ""
    preview = if String.length(content) > 200, do: String.slice(content, 0, 200) <> "…", else: content

    cache_info = if cache > 0, do: " (#{format_number(cache)} cached)", else: ""
    base = "💬 Responded (#{format_number(input)} in / #{format_number(output)} out#{cache_info})"
    if preview != "", do: base <> "\n" <> preview, else: base
  end

  defp delta_summary(%{kind: "tool.call", payload: p}) do
    name = p["name"] || "unknown"
    input = p["input"] || %{}
    params = input |> Enum.map(fn {k, v} -> "#{k}=#{inspect_short(v)}" end) |> Enum.join(", ")
    "🔧 Calling **#{name}** with: {#{params}}"
  end

  defp delta_summary(%{kind: "tool.result", payload: p}) do
    name = p["name"] || "unknown"
    status = p["status"] || "unknown"
    output = p["output"] || ""
    len = if is_binary(output), do: String.length(output), else: String.length(inspect(output))

    if status in ["ok", "success"] do
      "✅ #{name} succeeded (#{format_number(len)} chars)"
    else
      error_preview = if is_binary(output), do: String.slice(output, 0, 100), else: inspect(output, limit: 3)
      "❌ #{name} failed: #{error_preview}"
    end
  end

  defp delta_summary(%{kind: "llm.stream_chunk", payload: p}) do
    text = p["text"] || ""
    len = String.length(text)
    preview = if len > 80, do: String.slice(text, 0, 80) <> "…", else: text
    "💬 Stream chunk (#{len} chars): #{preview}"
  end

  defp delta_summary(%{kind: "familiard.escalation", payload: p}) do
    level = p["level"] || "info"
    msg = p["message"] || ""
    "⚠️ Escalation [#{level}]: #{String.slice(msg, 0, 120)}"
  end

  defp delta_summary(%{kind: "cron.fired", payload: p}) do
    job = p["job_name"] || "unknown"
    count = p["fired_count"]
    label = p["label"]
    name = label || job
    count_str = if count, do: " (##{count})", else: ""
    "⏰ Cron job **#{name}**#{count_str} fired"
  end

  defp delta_summary(%{kind: "plugin.loaded", payload: p}) do
    name = p["name"] || "unknown"
    "🔌 Plugin loaded: **#{name}**"
  end

  defp delta_summary(%{kind: "plugin.unloaded", payload: p}) do
    name = p["name"] || "unknown"
    "🔌 Plugin unloaded: **#{name}**"
  end

  defp delta_summary(%{kind: "send_message", payload: p}) do
    channel = resolve_channel(p["channel_id"] || "?")
    text = p["text"] || p["content"] || ""
    truncated = if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
    "📤 Sent to #{channel}: \"#{truncated}\""
  end

  defp delta_summary(%{kind: "error" <> _, payload: p}) do
    msg = p["message"] || p["error"] || p["reason"] || ""
    truncated = if String.length(msg) > 120, do: String.slice(msg, 0, 120) <> "…", else: msg
    "❌ #{truncated}"
  end

  defp delta_summary(%{kind: "session." <> action, payload: p}) do
    chat_id = p["chat_id"] || ""
    "📋 Session #{action}" <> if(chat_id != "", do: " (#{chat_id})", else: "")
  end

  defp delta_summary(%{kind: kind, payload: p}) do
    # Readable fallback: show key=value pairs instead of Elixir inspect
    summary = readable_payload_summary(p)
    "#{kind_emoji(kind)} #{kind}" <> if(summary != "", do: ": #{summary}", else: "")
  end

  # Convert delta_summary markdown to safe HTML
  defp delta_summary_html(delta) do
    bold_re = Regex.compile!("\\*\\*(.+?)\\*\\*")

    delta
    |> delta_summary()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> then(fn s -> Regex.replace(bold_re, s, "<strong>\\1</strong>") end)
    |> String.replace("\n", "<br/>")
  end

  defp readable_payload_summary(p) when map_size(p) == 0, do: ""

  defp readable_payload_summary(p) do
    p
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] or v == %{} end)
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect_short(v)}" end)
    |> Enum.join(", ")
    |> then(fn s ->
      if String.length(s) > 140, do: String.slice(s, 0, 140) <> "…", else: s
    end)
  end

  defp inspect_short(v) when is_binary(v) do
    if String.length(v) > 60, do: "\"#{String.slice(v, 0, 60)}…\"", else: "\"#{v}\""
  end

  defp inspect_short(v), do: inspect(v, limit: 3, printable_limit: 60)

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
  end

  defp format_number(n), do: to_string(n)

  # ── Token aggregation ──────────────────────────────────────────────────

  defp trace_token_summary(all_deltas, root_id) do
    by_parent = Enum.group_by(all_deltas, & &1.parent_id)
    descendants = collect_descendants(root_id, by_parent)

    llm_responses = Enum.filter(descendants, &(&1.kind == "llm.response"))
    count = length(llm_responses)

    {total_in, total_out} =
      Enum.reduce(llm_responses, {0, 0}, fn d, {ai, ao} ->
        usage = d.payload["usage"] || %{}
        {ai + (usage["input_tokens"] || 0), ao + (usage["output_tokens"] || 0)}
      end)

    if count > 0 do
      "📊 Total: #{format_number(total_in)} in / #{format_number(total_out)} out across #{count} LLM call#{if count != 1, do: "s", else: ""}"
    else
      nil
    end
  end

  defp collect_descendants(parent_id, by_parent) do
    children = Map.get(by_parent, parent_id, [])

    Enum.flat_map(children, fn child ->
      [child | collect_descendants(child.id, by_parent)]
    end)
  end

  # ── Waterfall data ─────────────────────────────────────────────────────

  defp build_waterfall(all_deltas, root_id, root_ts) do
    by_parent = Enum.group_by(all_deltas, & &1.parent_id)
    descendants = collect_descendants(root_id, by_parent)
    all_in_trace = [Enum.find(all_deltas, &(&1.id == root_id)) | descendants] |> Enum.reject(&is_nil/1)

    trace_end = all_in_trace |> Enum.map(& &1.ts) |> Enum.max(fn -> root_ts end)
    total_duration = max(trace_end - root_ts, 1)

    all_in_trace
    |> Enum.sort_by(& &1.ts)
    |> Enum.map(fn d ->
      offset_ms = d.ts - root_ts
      offset_pct = offset_ms / total_duration * 100.0

      # Estimate duration: for pairs like tool.call->tool.result, use next sibling
      duration_ms = estimate_duration(d, all_in_trace, total_duration)
      width_pct = max(duration_ms / total_duration * 100.0, 2.0)

      %{
        id: d.id,
        kind: d.kind,
        category: delta_category(d),
        offset_pct: Float.round(offset_pct * 1.0, 1),
        width_pct: Float.round(min(width_pct, 100.0 - offset_pct) * 1.0, 1),
        offset_ms: offset_ms,
        duration_ms: duration_ms,
        label: waterfall_label(d)
      }
    end)
  end

  defp estimate_duration(delta, all_in_trace, total_duration) do
    sorted = Enum.sort_by(all_in_trace, & &1.ts)
    idx = Enum.find_index(sorted, &(&1.id == delta.id))
    next = Enum.at(sorted, (idx || 0) + 1)

    cond do
      next != nil -> max(next.ts - delta.ts, 1)
      true -> max(div(total_duration, 10), 1)
    end
  end

  defp waterfall_label(%{kind: "message.received"}), do: "msg"
  defp waterfall_label(%{kind: "llm.call"}), do: "llm→"
  defp waterfall_label(%{kind: "llm.response"}), do: "←llm"
  defp waterfall_label(%{kind: "tool.call", payload: p}), do: p["name"] || "tool→"
  defp waterfall_label(%{kind: "tool.result", payload: p}), do: "←#{p["name"] || "tool"}"
  defp waterfall_label(%{kind: kind}), do: kind

  # Category-based waterfall colors
  # External input (incoming signals): green
  # Remote service (outbound calls): blue
  # Internal operation (local work): amber
  defp waterfall_color(:external_input), do: "#68d391"
  defp waterfall_color(:remote_service), do: "#63b3ed"
  defp waterfall_color(:internal), do: "#fbd38d"
  defp waterfall_color(_), do: "#a0aec0"

  # Classify a delta into a category based on kind + tool name
  defp delta_category(%{kind: "message.received"}), do: :external_input
  defp delta_category(%{kind: "familiard.escalation"}), do: :external_input
  defp delta_category(%{kind: "llm.call"}), do: :remote_service
  defp delta_category(%{kind: "llm.response"}), do: :remote_service
  defp delta_category(%{kind: "llm.error"}), do: :remote_service
  defp delta_category(%{kind: "send_message"}), do: :remote_service
  defp delta_category(%{kind: "cron.fired"}), do: :internal

  defp delta_category(%{kind: kind, payload: p}) when kind in ["tool.call", "tool.result"] do
    name = (p["name"] || "") |> String.downcase()

    cond do
      # Remote service tools — outbound API calls
      name in ["message", "web_search", "web_fetch", "browser", "image"] ->
        :remote_service

      # Internal tools — local file/compute operations
      name in ["read", "write", "edit", "exec", "process", "memory_search", "memory_get"] ->
        :internal

      # Heuristics for other tool names
      String.contains?(name, ["api", "http", "fetch", "search", "send", "upload"]) ->
        :remote_service

      String.contains?(name, ["read", "write", "file", "vault", "memory", "local", "exec"]) ->
        :internal

      # Default tool calls to internal
      true ->
        :internal
    end
  end

  defp delta_category(_), do: :internal

  defp token_badge(%{kind: "llm.response", payload: p}) do
    usage = p["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    total = input + output

    if total > 0 do
      "📊 #{format_number(input)} in / #{format_number(output)} out (#{format_number(total)} total)"
    else
      nil
    end
  end

  defp token_badge(_), do: nil

  defp stat_card_style do
    "background:#1a1d2e;border:1px solid #2d3748;border-radius:12px;padding:16px;"
  end

  defp error_count_style(count) when count > 0 do
    "color:#fc8181;font-size:1.4rem;font-weight:bold;margin-top:4px;"
  end

  defp error_count_style(_) do
    "color:#68d391;font-size:1.4rem;font-weight:bold;margin-top:4px;"
  end

  # ── Payload card component ─────────────────────────────────────────────

  @doc false
  def render_payload_card(assigns) do
    ~H"""
    <div phx-click="noop" style="font-size:0.85rem;">
      <% fields = payload_card_fields(@delta) %>
      <div style="display:grid;grid-template-columns:min-content 1fr;gap:3px 12px;align-items:start;">
        <%= for {label, value, wrap} <- fields do %>
          <div style="color:#718096;font-size:0.78rem;white-space:nowrap;padding-top:2px;"><%= label %></div>
          <%= if wrap do %>
            <div style="color:#e2e8f0;font-size:0.82rem;white-space:pre-wrap;word-break:break-word;max-height:200px;overflow-y:auto;background:#0d1117;padding:4px 6px;border-radius:3px;"><%= value %></div>
          <% else %>
            <div style="color:#e2e8f0;font-size:0.82rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"><%= value %></div>
          <% end %>
        <% end %>
      </div>
      <div style="margin-top:6px;text-align:right;">
        <span
          phx-click="toggle_raw"
          phx-value-id={@delta.id}
          style="color:#4a5568;font-size:0.72rem;cursor:pointer;text-decoration:underline;user-select:none;"
        >
          <%= if MapSet.member?(@raw_visible, @delta.id), do: "▲ hide raw", else: "▼ raw json" %>
        </span>
      </div>
      <%= if MapSet.member?(@raw_visible, @delta.id) do %>
        <pre style="color:#718096;font-size:0.75rem;white-space:pre-wrap;word-break:break-all;max-height:280px;overflow-y:auto;margin-top:4px;background:#0d1117;padding:8px;border-radius:4px;border:1px solid #2d3748;"><%= Jason.encode!(truncate_base64_in_payload(@delta.payload), pretty: true) %></pre>
      <% end %>
    </div>
    """
  end

  # Returns [{label, value, wrap?}] tuples for the payload card
  defp payload_card_fields(%{kind: "message.received", payload: p}) do
    user = resolve_user(p["author_id"] || p["username"] || "?")
    channel = resolve_channel(p["channel_id"] || "?")
    text = p["text"] || ""

    guild_rows =
      if p["guild_id"], do: [{"Guild", resolve_guild(p["guild_id"]), false}], else: []

    attach_count = if is_list(p["attachments"]), do: length(p["attachments"]), else: 0

    attach_rows =
      if attach_count > 0, do: [{"Attachments", "#{attach_count} file(s)", false}], else: []

    [{"From", user, false}, {"Channel", channel, false}] ++
      guild_rows ++
      [{"Message", text, String.length(text) > 60}] ++
      attach_rows
  end

  defp payload_card_fields(%{kind: "llm.response", payload: p}) do
    usage = p["usage"] || %{}
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    cached = usage["cache_read_input_tokens"] || 0
    content = p["content"] || ""

    tokens_str =
      "#{format_number(input)} in / #{format_number(output)} out" <>
        if(cached > 0, do: " / #{format_number(cached)} cached", else: "")

    model_rows = if p["model"], do: [{"Model", p["model"], false}], else: []
    content_rows = if content != "", do: [{"Response", content, true}], else: []

    model_rows ++ [{"Tokens", tokens_str, false}] ++ content_rows
  end

  defp payload_card_fields(%{kind: "llm.call", payload: p}) do
    tools = p["tools"] || []
    tool_count = if is_list(tools), do: length(tools), else: 0

    tool_names =
      if is_list(tools) and tool_count > 0 do
        tools
        |> Enum.map(fn t -> if is_map(t), do: t["name"] || "?", else: inspect(t) end)
        |> Enum.join(", ")
      else
        "none"
      end

    msg_count =
      p["message_count"] ||
        (if is_list(p["messages"]), do: length(p["messages"]), else: "?")

    tools_str = if tool_count > 0, do: "#{tool_count} (#{tool_names})", else: "none"
    model_rows = if p["model"], do: [{"Model", p["model"], false}], else: []

    model_rows ++ [{"Messages", "#{msg_count}", false}, {"Tools", tools_str, false}]
  end

  defp payload_card_fields(%{kind: "tool.call", payload: p}) do
    name = p["name"] || "unknown"
    input = p["input"] || %{}

    param_rows =
      Enum.map(input, fn {k, v} ->
        str_v =
          if is_binary(v) and String.length(v) > 100,
            do: String.slice(v, 0, 100) <> "…",
            else: inspect_short(v)

        {"  #{k}", str_v, false}
      end)

    [{"Tool", name, false}] ++ param_rows
  end

  defp payload_card_fields(%{kind: "tool.result", payload: p}) do
    name = p["name"] || "unknown"
    status = p["status"] || "unknown"
    output = p["output"] || ""

    status_display =
      case to_string(status) do
        s when s in ["ok", "success", "true"] -> "✅ #{s}"
        s -> "❌ #{s}"
      end

    output_str =
      if is_binary(output) do
        if String.length(output) > 200, do: String.slice(output, 0, 200) <> "…", else: output
      else
        inspect(output, limit: 5, printable_limit: 200)
      end

    wrap = is_binary(output_str) and String.length(output_str) > 60

    [{"Tool", name, false}, {"Status", status_display, false}, {"Output", output_str, wrap}]
  end

  defp payload_card_fields(%{payload: p}) when map_size(p) == 0, do: []

  defp payload_card_fields(%{payload: p}) do
    p
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Enum.map(fn {k, v} ->
      {str_v, wrap} =
        case v do
          s when is_binary(s) ->
            truncated =
              if String.length(s) > 120, do: String.slice(s, 0, 120) <> "…", else: s

            {truncated, String.length(s) > 60}

          _ ->
            {inspect_short(v), false}
        end

      {to_string(k), str_v, wrap}
    end)
  end

  # ── Image helpers ──────────────────────────────────────────────────────

  @doc false
  def image_modal(assigns) do
    ~H"""
    <%= if @image_modal do %>
      <div
        phx-click="close_image_modal"
        style="position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.85);display:flex;align-items:center;justify-content:center;padding:20px;cursor:pointer;"
      >
        <div style="max-width:95vw;max-height:95vh;display:flex;flex-direction:column;align-items:center;gap:12px;" phx-click="close_image_modal">
          <div style="color:#e2e8f0;font-size:0.9rem;font-weight:bold;"><%= @image_modal.label %></div>
          <img
            src={"data:#{@image_modal.media_type};base64,#{@image_modal.base64}"}
            style="max-width:90vw;max-height:85vh;border-radius:8px;box-shadow:0 8px 32px rgba(0,0,0,0.6);"
            onerror="this.style.display='none';this.nextElementSibling.style.display='block';"
          />
          <div style="display:none;color:#fc8181;font-size:1rem;padding:20px;">⚠️ Failed to load image</div>
          <div style="display:flex;gap:12px;align-items:center;">
            <span style="color:#718096;font-size:0.75rem;"><%= @image_modal.media_type %> · <%= format_base64_size(@image_modal.base64) %></span>
            <button
              phx-click="close_image_modal"
              style="background:#2d3748;color:#e2e8f0;border:none;padding:6px 16px;border-radius:6px;cursor:pointer;font-size:0.8rem;"
            >
              Close (ESC)
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp format_base64_size(base64) when is_binary(base64) do
    bytes = div(byte_size(base64) * 3, 4)

    cond do
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes > 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_base64_size(_), do: "unknown size"

  defp truncate_base64_in_payload(payload) when is_map(payload) do
    Map.new(payload, fn
      {"images", images} when is_list(images) ->
        truncated =
          Enum.map(images, fn img ->
            case img do
              %{"base64" => b64} when is_binary(b64) and byte_size(b64) > 100 ->
                Map.put(img, "base64", "[#{byte_size(b64)} chars base64 — rendered above]")

              other ->
                other
            end
          end)

        {"images", truncated}

      {"content", content} when is_list(content) ->
        truncated =
          Enum.map(content, fn
            %{"type" => "image", "source" => %{"data" => d} = src} = block when is_binary(d) and byte_size(d) > 100 ->
              %{block | "source" => Map.put(src, "data", "[#{byte_size(d)} chars base64 — rendered above]")}

            other ->
              other
          end)

        {"content", truncated}

      {key, val} when is_binary(val) and byte_size(val) > 1000 ->
        if Kyber.Web.ImageDetector.guess_media_type_public(val) do
          {key, "[#{byte_size(val)} chars base64 image — rendered above]"}
        else
          {key, val}
        end

      {key, val} when is_map(val) ->
        {key, truncate_base64_in_payload(val)}

      other ->
        other
    end)
  end

  defp truncate_base64_in_payload(other), do: other
end
