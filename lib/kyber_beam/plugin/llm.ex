defmodule Kyber.Plugin.LLM do
  @moduledoc """
  Anthropic API integration as a Kyber plugin.

  Runs as a GenServer under `Kyber.Plugin.Manager`. On startup it:
  1. Loads auth config from `~/.openclaw/agents/main/agent/auth-profiles.json`
  2. Detects OAuth vs API key by token prefix
  3. Registers an `:llm_call` effect handler with the Core executor

  ## Token prefix detection
  - `"sk-ant-oat"` prefix → OAuth token (Bearer auth + special headers)
  - `"sk-ant-api"` prefix → API key (`x-api-key` header)

  ## Effect handler
  When a `:llm_call` effect fires, the handler:
  1. Retrieves conversation history from `Kyber.Session`
  2. Builds a messages list from the effect payload
  3. POSTs to `https://api.anthropic.com/v1/messages`
  4. Emits `"llm.response"` or `"llm.error"` delta back into Core
  """

  use GenServer
  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 8192
  @auth_profiles_path "~/.openclaw/agents/main/agent/auth-profiles.json"

  # ── Plugin behaviour ──────────────────────────────────────────────────────

  def name, do: "llm"

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the LLM plugin."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load auth configuration from auth-profiles.json.

  Returns `{:ok, %{token: token, type: :oauth | :api_key}}` or `{:error, reason}`.
  """
  @spec load_auth_config() :: {:ok, map()} | {:error, term()}
  def load_auth_config do
    load_auth_config(@auth_profiles_path)
  end

  @spec load_auth_config(String.t()) :: {:ok, map()} | {:error, term()}
  def load_auth_config(path) do
    expanded = Path.expand(path)

    with {:ok, raw} <- File.read(expanded),
         {:ok, data} <- Jason.decode(raw) do
      token = extract_token(data)
      if token do
        auth_type = detect_auth_type(token)
        {:ok, %{token: token, type: auth_type}}
      else
        {:error, :no_token_found}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Detect whether a token is OAuth or API key based on prefix."
  @spec detect_auth_type(String.t()) :: :oauth | :api_key
  def detect_auth_type("sk-ant-oat" <> _), do: :oauth
  def detect_auth_type("sk-ant-api" <> _), do: :api_key
  def detect_auth_type(_), do: :api_key

  @doc """
  Build the HTTP request headers for a given auth config.
  """
  @spec build_headers(map()) :: [{String.t(), String.t()}]
  def build_headers(%{type: :oauth, token: token}) do
    [
      {"Authorization", "Bearer #{token}"},
      {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20"},
      {"user-agent", "claude-cli/2.1.62"},
      {"x-app", "cli"},
      {"content-type", "application/json"}
    ]
  end

  def build_headers(%{type: :api_key, token: token}) do
    [
      {"x-api-key", token},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  @doc """
  Build the messages list for an Anthropic API call from effect data.

  Effect data may include:
  - `"history"` — list of prior message maps `%{role, content}`
  - `"text"` — current user message
  - `"messages"` — explicit messages list (overrides history+text)
  """
  @spec build_messages(map()) :: [map()]
  def build_messages(payload) do
    cond do
      is_list(payload["messages"]) ->
        payload["messages"]

      is_binary(payload["text"]) ->
        history = build_history_messages(payload["history"] || [])
        history ++ [%{"role" => "user", "content" => payload["text"]}]

      true ->
        []
    end
  end

  @doc """
  Call the Anthropic Messages API with the given parameters.

  Returns `{:ok, response_body}` or `{:error, %{error: msg, status: code}}`.
  """
  @spec call_api(map(), map()) :: {:ok, map()} | {:error, map()}
  def call_api(auth_config, params) do
    headers = build_headers(auth_config)

    body = %{
      "model" => params["model"] || @default_model,
      "max_tokens" => params["max_tokens"] || @default_max_tokens,
      "messages" => params["messages"] || []
    }

    body =
      if params["system"],
        do: Map.put(body, "system", params["system"]),
        else: body

    case Req.post(@anthropic_url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        error_msg = get_in(body, ["error", "message"]) || "API error"
        {:error, %{error: error_msg, status: status}}

      {:error, reason} ->
        {:error, %{error: inspect(reason), status: 0}}
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    core = Keyword.get(opts, :core, Kyber.Core)
    session = Keyword.get(opts, :session, Kyber.Session)
    auth_path = Keyword.get(opts, :auth_path, @auth_profiles_path)

    state = %{
      core: core,
      session: session,
      auth_config: nil,
      auth_path: auth_path
    }

    # Load auth config asynchronously so init doesn't block if file is missing
    case load_auth_config(auth_path) do
      {:ok, auth_config} ->
        Logger.info("[Kyber.Plugin.LLM] auth loaded (type: #{auth_config.type})")
        state = %{state | auth_config: auth_config}
        send(self(), :register_handlers)
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[Kyber.Plugin.LLM] auth load failed: #{inspect(reason)} — plugin will run without auth")
        send(self(), :register_handlers)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:register_handlers, state) do
    register_effect_handler(state)
    Logger.info("[Kyber.Plugin.LLM] effect handler registered")
    {:noreply, state}
  end

  def handle_info({:update_auth, auth_config}, state) do
    {:noreply, %{state | auth_config: auth_config}}
  end

  @impl true
  def handle_call(:get_auth_config, _from, state) do
    {:reply, state.auth_config, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Kyber.Plugin.LLM] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("[Kyber.Plugin.LLM] terminating: #{inspect(reason)}")
    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp register_effect_handler(%{core: core, session: session}) do
    # Capture plugin_pid (self()) BEFORE the closure, so the handler always
    # fetches the current auth config at invocation time rather than using the
    # stale value that was closed over at registration time. This allows
    # handle_info({:update_auth, ...}) to propagate token updates correctly.
    plugin_pid = self()

    handler = fn effect ->
      auth_config = GenServer.call(plugin_pid, :get_auth_config)
      handle_llm_call(effect, core, session, auth_config)
    end

    try do
      Kyber.Core.register_effect_handler(core, :llm_call, handler)
    catch
      :exit, reason ->
        Logger.warning("[Kyber.Plugin.LLM] could not register handler (core not ready): #{inspect(reason)}")
      kind, reason ->
        Logger.error("[Kyber.Plugin.LLM] failed to register handler: #{kind} #{inspect(reason)}")
    end
  end

  defp handle_llm_call(effect, core, session, auth_config) do
    payload = Map.get(effect, :payload, %{})
    origin = Map.get(effect, :origin)
    parent_id = Map.get(effect, :delta_id)

    # Get conversation history from session
    chat_id = chat_id_from_origin(origin)
    history =
      if chat_id && Process.whereis(session) do
        Kyber.Session.get_history(session, chat_id)
        |> Enum.map(fn delta ->
          %{"role" => "user", "content" => Map.get(delta.payload, "text", "")}
        end)
      else
        []
      end

    # Build messages
    messages =
      if is_list(payload["messages"]) do
        payload["messages"]
      else
        text = payload["text"] || ""
        history ++ [%{"role" => "user", "content" => text}]
      end

    params = %{
      "model" => payload["model"] || @default_model,
      "max_tokens" => payload["max_tokens"] || @default_max_tokens,
      "messages" => messages,
      "system" => payload["system"]
    }

    case auth_config do
      nil ->
        emit_error(core, "no auth config", 0, origin, parent_id)

      config ->
        case call_api(config, params) do
          {:ok, response} ->
            content = extract_content(response)
            delta = Kyber.Delta.new(
              "llm.response",
              %{
                "content" => content,
                "model" => response["model"],
                "usage" => response["usage"],
                "stop_reason" => response["stop_reason"]
              },
              {:subagent, parent_id || "llm"},
              parent_id
            )

            try do
              Kyber.Core.emit(core, delta)
            rescue
              e -> Logger.error("[Kyber.Plugin.LLM] failed to emit response: #{inspect(e)}")
            end

          {:error, %{error: error_msg, status: status}} ->
            emit_error(core, error_msg, status, origin, parent_id)
        end
    end
  end

  defp emit_error(core, error_msg, status, origin, parent_id) do
    delta = Kyber.Delta.new(
      "llm.error",
      %{"error" => error_msg, "status" => status},
      origin || {:system, "llm"},
      parent_id
    )

    try do
      Kyber.Core.emit(core, delta)
    rescue
      e -> Logger.error("[Kyber.Plugin.LLM] failed to emit error delta: #{inspect(e)}")
    end
  end

  defp extract_content(%{"content" => [%{"text" => text} | _]}), do: text
  defp extract_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end
  defp extract_content(_), do: ""

  defp chat_id_from_origin({:channel, _ch, chat_id, _sender}), do: chat_id
  defp chat_id_from_origin({:human, user_id}), do: user_id
  defp chat_id_from_origin(_), do: nil

  defp build_history_messages(history) when is_list(history) do
    Enum.map(history, fn
      %{"role" => role, "content" => content} -> %{"role" => role, "content" => content}
      %{role: role, content: content} -> %{"role" => to_string(role), "content" => content}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_history_messages(_), do: []

  defp extract_token(%{"claudeAiOauth" => %{"accessToken" => token}}) when is_binary(token),
    do: token

  defp extract_token(%{"oauthToken" => token}) when is_binary(token), do: token
  defp extract_token(%{"apiKey" => token}) when is_binary(token), do: token
  defp extract_token(%{"token" => token}) when is_binary(token), do: token

  defp extract_token(data) when is_map(data) do
    # Search recursively for any key that looks like a token
    Enum.find_value(data, fn {_k, v} ->
      case v do
        %{} -> extract_token(v)
        str when is_binary(str) and byte_size(str) > 20 ->
          if String.starts_with?(str, "sk-ant-"), do: str, else: nil
        _ -> nil
      end
    end)
  end

  defp extract_token(_), do: nil
end
