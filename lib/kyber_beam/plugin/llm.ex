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
  1. Stores the user message in `Kyber.Session` before the API call
  2. Retrieves conversation history from `Kyber.Session`
  3. Runs a multi-turn tool loop (up to 10 iterations)
  4. Stores the assistant response in `Kyber.Session` after completion
  5. Emits `"llm.response"` or `"llm.error"` delta back into Core

  ## Tool loop
  The tool loop calls the API with tool definitions. If the model responds
  with `stop_reason == "tool_use"`, each tool call is executed via
  `Kyber.ToolExecutor` and results are fed back as `tool_result` blocks.
  Repeats until `stop_reason == "end_turn"` or max iterations (10).
  """

  use GenServer
  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
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
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta",
       "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"},
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

    # Include tools if provided
    body =
      case params["tools"] do
        tools when is_list(tools) and length(tools) > 0 ->
          Map.put(body, "tools", tools)

        _ ->
          body
      end

    body =
      case {auth_config.type, params["system"]} do
        {:oauth, system} when is_binary(system) ->
          # OAuth tokens require Claude Code identity prefix and system as array
          Map.put(body, "system", [
            %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."},
            %{"type" => "text", "text" => system}
          ])

        {:oauth, nil} ->
          Map.put(body, "system", [
            %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."}
          ])

        {_, system} when is_binary(system) ->
          Map.put(body, "system", system)

        _ ->
          body
      end

    system_info =
      case body["system"] do
        list when is_list(list) -> "yes (#{length(list)} blocks)"
        str when is_binary(str) -> "yes (#{String.length(str)} chars)"
        _ -> "no"
      end

    tools_info =
      case body["tools"] do
        tools when is_list(tools) -> "#{length(tools)} tools"
        _ -> "none"
      end

    Logger.info(
      "[Kyber.Plugin.LLM] calling API: model=#{body["model"]}, " <>
        "messages=#{length(body["messages"] || [])}, system=#{system_info}, tools=#{tools_info}"
    )

    case Req.post(@anthropic_url, headers: headers, json: body, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[Kyber.Plugin.LLM] API error #{status}: #{inspect(body)}")
        error_msg = get_in(body, ["error", "message"]) || inspect(body)
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
        Logger.warning(
          "[Kyber.Plugin.LLM] auth load failed: #{inspect(reason)} — plugin will run without auth"
        )

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

  def handle_info(msg, state) do
    Logger.warning("[Kyber.Plugin.LLM] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_auth_config, _from, state) do
    {:reply, state.auth_config, state}
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
        Logger.warning(
          "[Kyber.Plugin.LLM] could not register handler (core not ready): #{inspect(reason)}"
        )

      kind, reason ->
        Logger.error(
          "[Kyber.Plugin.LLM] failed to register handler: #{kind} #{inspect(reason)}"
        )
    end
  end

  defp handle_llm_call(effect, core, session, auth_config) do
    payload = Map.get(effect, :payload, %{})
    origin = Map.get(effect, :origin)
    parent_id = Map.get(effect, :delta_id)

    # Derive chat_id from origin for session keying
    chat_id = chat_id_from_origin(origin)

    # Get conversation history from session — preserving proper roles.
    # Cap to the last 20 messages to prevent unbounded history growth and API failures.
    history =
      if chat_id && process_alive?(session) do
        Kyber.Session.get_history(session, chat_id)
        |> Enum.take(-20)
        |> Enum.map(fn delta ->
          role = Map.get(delta.payload, "role", "user")
          content = Map.get(delta.payload, "content", "")
          %{"role" => role, "content" => content}
        end)
      else
        []
      end

    # Build current user message
    text = payload["text"] || ""

    # Store user message in session BEFORE API call
    if chat_id && process_alive?(session) do
      user_delta =
        Kyber.Delta.new(
          "session.user",
          %{"role" => "user", "content" => text},
          origin
        )

      Kyber.Session.add_message(session, chat_id, user_delta)
    end

    # Build messages list for the API call
    messages =
      if is_list(payload["messages"]) do
        payload["messages"]
      else
        history ++ [%{"role" => "user", "content" => text}]
      end

    # Load system prompt: explicit payload > vault knowledge context
    system_prompt = payload["system"] || build_system_prompt(chat_id)

    case auth_config do
      nil ->
        emit_error(core, "no auth config", 0, origin, parent_id)

      config ->
        case run_tool_loop(messages, system_prompt, config) do
          {:ok, response} ->
            content = extract_content(response)

            # Store assistant response in session AFTER successful API call
            if chat_id && process_alive?(session) do
              asst_delta =
                Kyber.Delta.new(
                  "session.assistant",
                  %{"role" => "assistant", "content" => content},
                  origin
                )

              Kyber.Session.add_message(session, chat_id, asst_delta)
            end

            # Derive channel from original origin for routing the response back
            channel_id =
              case origin do
                {:channel, "discord", cid, _} -> cid
                _ -> nil
              end

            response_payload =
              %{
                "content" => content,
                "model" => response["model"],
                "usage" => response["usage"],
                "stop_reason" => response["stop_reason"]
              }
              |> then(fn p ->
                if channel_id, do: Map.put(p, "channel_id", channel_id), else: p
              end)

            # Preserve the original origin so the reducer can route the response
            delta =
              Kyber.Delta.new(
                "llm.response",
                response_payload,
                origin || {:system, "llm"},
                parent_id
              )

            try do
              Kyber.Core.emit(core, delta)
            rescue
              e ->
                Logger.error("[Kyber.Plugin.LLM] failed to emit response: #{inspect(e)}")
            end

            # Reinforce memories whose tags appear in the response.
            # Lightweight — just tag extraction, no LLM call.
            reinforce_memories(content)

          {:error, %{error: error_msg, status: status}} ->
            emit_error(core, error_msg, status, origin, parent_id)

          {:error, reason} when is_binary(reason) ->
            emit_error(core, reason, 0, origin, parent_id)
        end
    end
  end

  # Multi-turn tool loop. Calls the API, executes any tool_use blocks,
  # and repeats until stop_reason is end_turn (or max iterations reached).
  defp run_tool_loop(messages, system_prompt, auth_config, remaining \\ 10)

  defp run_tool_loop(_messages, _system_prompt, _auth_config, 0) do
    {:error, "tool loop limit reached (max 10 iterations)"}
  end

  defp run_tool_loop(messages, system_prompt, auth_config, remaining) do
    params = %{
      "model" => @default_model,
      "max_tokens" => @default_max_tokens,
      "messages" => messages,
      "system" => system_prompt,
      "tools" => Kyber.Tools.definitions()
    }

    case call_api(auth_config, params) do
      {:ok, %{"stop_reason" => "tool_use", "content" => content_blocks} = _response} ->
        # Extract all tool_use blocks from the response
        tool_uses = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))

        Logger.info(
          "[Kyber.Plugin.LLM] tool_use: #{length(tool_uses)} call(s): " <>
            Enum.map_join(tool_uses, ", ", & &1["name"])
        )

        # Build assistant turn with all content blocks (preserves tool_use blocks)
        assistant_msg = %{"role" => "assistant", "content" => content_blocks}

        # Execute each tool and build tool_result blocks
        tool_results =
          Enum.map(tool_uses, fn tu ->
            tool_name = tu["name"]
            tool_input = tu["input"] || %{}

            Logger.debug("[Kyber.Plugin.LLM] executing tool: #{tool_name} #{inspect(tool_input)}")

            case Kyber.ToolExecutor.execute(tool_name, tool_input) do
              {:ok, output} ->
                %{
                  "type" => "tool_result",
                  "tool_use_id" => tu["id"],
                  "content" => output
                }

              {:error, err} ->
                Logger.warning("[Kyber.Plugin.LLM] tool error (#{tool_name}): #{err}")

                %{
                  "type" => "tool_result",
                  "tool_use_id" => tu["id"],
                  "content" => "Error: #{err}",
                  "is_error" => true
                }
            end
          end)

        user_result_msg = %{"role" => "user", "content" => tool_results}

        # Continue loop with updated message history
        run_tool_loop(
          messages ++ [assistant_msg, user_result_msg],
          system_prompt,
          auth_config,
          remaining - 1
        )

      {:ok, response} ->
        # end_turn or any other stop_reason — we're done
        {:ok, response}

      {:error, _} = err ->
        err
    end
  end

  defp emit_error(core, error_msg, status, origin, parent_id) do
    delta =
      Kyber.Delta.new(
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

  # Build the system prompt by combining SOUL.md with vault context.
  # Loads:
  #   1. SOUL.md identity (from vault or file fallback)
  #   2. Long-term memory (MEMORY.md, auto-curated by Memory.Consolidator)
  #   3. Today's memory note (if present in vault)
  #
  # Falls back gracefully if Kyber.Knowledge is not running.
  defp build_system_prompt(_chat_id) do
    # Step 1: Load SOUL.md — prefer vault, fall back to file
    soul_content =
      case safe_knowledge_call({:get_tiered, "identity/SOUL.md", :l2}) do
        {:ok, %{body: body}} when is_binary(body) and body != "" -> body
        _ -> load_soul_from_file()
      end

    # Step 2: Long-term memory (MEMORY.md, regenerated by Memory.Consolidator)
    long_term_memory =
      case safe_knowledge_call({:get_tiered, "identity/MEMORY.md", :l2}) do
        {:ok, %{body: body}} when is_binary(body) and body != "" ->
          "\n\n## Long-Term Memory (auto-curated)\n#{body}"

        _ ->
          # Fall back to reading directly from file
          path = Path.expand("~/.kyber/vault/identity/MEMORY.md")
          case File.read(path) do
            {:ok, content} when content != "" ->
              "\n\n## Long-Term Memory (auto-curated)\n#{content}"
            _ ->
              ""
          end
      end

    # Step 3: Today's memory note
    today = Date.to_string(Date.utc_today())

    memory_context =
      case safe_knowledge_call({:get_tiered, "memory/#{today}.md", :l2}) do
        {:ok, %{body: body}} when is_binary(body) and body != "" ->
          "\n\n## Today's Notes\n#{body}"

        _ ->
          ""
      end

    (soul_content || "") <> long_term_memory <> memory_context
  end

  # Call Kyber.Knowledge safely — returns nil if not running.
  defp safe_knowledge_call(request) do
    if Process.whereis(Kyber.Knowledge) do
      try do
        GenServer.call(Kyber.Knowledge, request, 2_000)
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  defp load_soul_from_file do
    # Try vault path first, then fallback to priv/vault
    paths = [
      Path.expand("~/.kyber/vault/identity/SOUL.md"),
      Path.join(:code.priv_dir(:kyber_beam), "vault/identity/SOUL.md")
    ]

    Enum.find_value(paths, fn path ->
      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    end)
  end

  # Extract tags from LLM response text and reinforce matching memories.
  # Only matches words that are at least 5 chars and not in the stopword list.
  # Intentionally lightweight: no LLM call, just simple word extraction.

  @tag_stopwords ~w(
    about after again also another archive around based batch because before being
    below build called change changes check class clause common complete config contains
    context create current cycle datum debug defined delta depends depth detail
    direct doing elixir error event example false found function given group guard handle
    handler have here include index inject input inside issue items just keep kind later
    layer level limit local logic match maybe means memory message might model module
    needs never might often only other output parse pattern place point process query
    quite reason reply reset response result return rules serve should since skill some
    stack state still store string struct system table target test their these thing
    this three through times token total toward under until update using value where while
    which within without would write
  )

  defp reinforce_memories(content) when is_binary(content) and content != "" do
    # Get existing memory tags from ETS so we only match real memory tags
    existing_tags =
      case :ets.whereis(:memory_pool) do
        :undefined ->
          MapSet.new()

        _table ->
          :ets.tab2list(:memory_pool)
          |> Enum.flat_map(fn {_, mem} -> mem.tags || [] end)
          |> MapSet.new()
      end

    words =
      content
      |> String.downcase()
      |> String.split(~r/[\s,.\-:;!?()\"'\[\]{}|<>\/\\]+/)
      |> Enum.filter(fn word ->
        len = String.length(word)
        # Minimum 5 chars, not a stopword
        len >= 5 and word not in @tag_stopwords
      end)
      |> Enum.uniq()

    # Prefer words that match actual memory tags; fall back to any qualifying word
    matched =
      if MapSet.size(existing_tags) > 0 do
        Enum.filter(words, &MapSet.member?(existing_tags, &1))
      else
        words
      end

    tags = Enum.take(matched, 20)

    if tags != [] do
      Kyber.Memory.Consolidator.reinforce(tags)
    end
  end

  defp reinforce_memories(_), do: :ok

  defp chat_id_from_origin({:channel, _ch, chat_id, _sender}), do: chat_id
  defp chat_id_from_origin({:human, user_id}), do: user_id
  defp chat_id_from_origin(_), do: nil

  # Safe process existence check — works with both atoms and pids
  defp process_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_), do: false

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
        %{} ->
          extract_token(v)

        str when is_binary(str) and byte_size(str) > 20 ->
          if String.starts_with?(str, "sk-ant-"), do: str, else: nil

        _ ->
          nil
      end
    end)
  end

  defp extract_token(_), do: nil
end
