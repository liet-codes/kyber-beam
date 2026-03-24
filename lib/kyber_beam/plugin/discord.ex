defmodule Kyber.Plugin.Discord do
  @moduledoc """
  Discord bot integration as a Kyber plugin.

  Connects to the Discord Gateway WebSocket, handles events, and registers
  a `:send_message` effect handler for sending messages via the REST API.

  ## Gateway
  - Connects to `wss://gateway.discord.gg/?v=10&encoding=json`
  - Handles opcodes: DISPATCH (0), HEARTBEAT (1), IDENTIFY (2), HELLO (10), HEARTBEAT_ACK (11)
  - Sends IDENTIFY with bot token + intents (GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT = 34307)
  - Maintains heartbeat interval; auto-reconnects on disconnect

  ## Event handling
  On `MESSAGE_CREATE` events, emits a `"message.received"` delta into Core.

  ## REST API
  Registers a `:send_message` effect handler that POSTs to Discord REST.

  ## Config
  Bot token from `DISCORD_BOT_TOKEN` environment variable or `:discord_bot_token` app config.
  """

  use GenServer
  require Logger

  @discord_api_base "https://discord.com/api/v10"

  # Discord Gateway opcodes
  @op_dispatch 0
  @op_heartbeat 1
  @op_identify 2
  @op_hello 10
  @op_heartbeat_ack 11

  # Max Discord message length (characters)
  @max_message_length 2000

  # Discord interaction types
  @interaction_type_application_command 2

  # Discord interaction response types — 5 = DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
  @interaction_response_deferred_channel_message 5

  # Slash command option types — 3 = STRING
  @option_type_string 3

  # Regex to detect fenced code blocks in LLM responses
  @code_block_pattern ~r/```(\w*)\n?(.*?)```/s

  # Intents: GUILDS (1) | GUILD_MESSAGES (512) | DIRECT_MESSAGES (4096) | MESSAGE_CONTENT (32768)
  # = 1 + 512 + 4096 + 32768 = 37377
  # Matches the TypeScript kyber build. Do NOT include GUILD_MEMBERS (2) — it's privileged.
  @gateway_intents 37377

  def name, do: "discord"

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Discord plugin."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a message to a Discord channel via REST API.

  Automatically chunks content >2000 characters. Supports optional reply
  threading and embeds.

  ## Options
    * `:reply_to` - message ID to reply to (adds message_reference)
    * `:embeds` - list of embed maps (title, description, color, fields, etc.)
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_message(token, channel_id, content, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    embeds = Keyword.get(opts, :embeds)
    chunks = chunk_message(content)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, idx}, :ok ->
      # Only first chunk gets reply_to and embeds
      chunk_opts = if idx == 0, do: [reply_to: reply_to, embeds: embeds], else: []
      body = build_message_body(chunk, chunk_opts)

      case post_message(token, channel_id, body) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Send a typing indicator to a Discord channel."
  @spec send_typing(String.t(), String.t()) :: :ok | {:error, term()}
  def send_typing(token, channel_id) do
    url = "#{@discord_api_base}/channels/#{channel_id}/typing"
    headers = [{"Authorization", "Bot #{token}"}]

    case Req.post(url, headers: headers, json: %{}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Add an emoji reaction to a message."
  @spec add_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_reaction(token, channel_id, message_id, emoji) do
    url = reaction_url(channel_id, message_id, emoji)
    headers = [{"Authorization", "Bot #{token}"}]

    case Req.put(url, headers: headers, json: %{}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove the bot's emoji reaction from a message."
  @spec remove_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_reaction(token, channel_id, message_id, emoji) do
    url = reaction_url(channel_id, message_id, emoji)
    headers = [{"Authorization", "Bot #{token}"}]

    case Req.delete(url, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a message. Bots can always delete their own messages; deleting others requires ManageMessages."
  @spec delete_message(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_message(token, channel_id, message_id) do
    with :ok <- validate_snowflake(channel_id),
         :ok <- validate_snowflake(message_id) do
      url = "#{@discord_api_base}/channels/#{channel_id}/messages/#{message_id}"
      headers = [{"Authorization", "Bot #{token}"}]

      case Req.delete(url, headers: headers) do
        # Discord returns 204 No Content on successful delete
        {:ok, %{status: 204}} -> :ok
        {:ok, %{status: status, body: body}} ->
          Logger.warning("[Kyber.Plugin.Discord] delete_message failed: status=#{status} body=#{inspect(body)}")
          {:error, %{status: status, body: body}}
        {:error, reason} ->
          Logger.warning("[Kyber.Plugin.Discord] delete_message transport error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @snowflake_pattern ~r/^[0-9]{17,20}$/
  defp validate_snowflake(id) when is_binary(id) do
    if Regex.match?(@snowflake_pattern, id), do: :ok, else: {:error, :invalid_snowflake_id}
  end
  defp validate_snowflake(_), do: {:error, :invalid_snowflake_id}

  @doc "Build the URL for a reaction endpoint. Emoji is URL-encoded."
  @spec reaction_url(String.t(), String.t(), String.t()) :: String.t()
  def reaction_url(channel_id, message_id, emoji) do
    encoded = URI.encode(emoji)
    "#{@discord_api_base}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me"
  end

  @doc "Fetch message history from a Discord channel."
  @spec fetch_messages(String.t(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def fetch_messages(token, channel_id, opts \\ []) do
    url = fetch_messages_url(channel_id, opts)
    headers = [{"Authorization", "Bot #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build the URL for fetching channel messages with query params."
  @spec fetch_messages_url(String.t(), keyword()) :: String.t()
  def fetch_messages_url(channel_id, opts) do
    limit = min(Keyword.get(opts, :limit, 50), 100)
    params = [{"limit", to_string(limit)}]
    params = if b = Keyword.get(opts, :before), do: params ++ [{"before", b}], else: params
    params = if a = Keyword.get(opts, :after), do: params ++ [{"after", a}], else: params
    query = URI.encode_query(params)
    "#{@discord_api_base}/channels/#{channel_id}/messages?#{query}"
  end

  @doc "Edit an existing Discord message."
  @spec edit_message(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_message(token, channel_id, message_id, new_content) do
    url = "#{@discord_api_base}/channels/#{channel_id}/messages/#{message_id}"
    headers = [{"Authorization", "Bot #{token}"}, {"Content-Type", "application/json"}]
    body = %{"content" => new_content}

    case Req.patch(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Send a file/image to a Discord channel via multipart upload."
  @spec send_file(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_file(token, channel_id, file_path, opts \\ []) do
    expanded = Path.expand(file_path)

    allowed =
      Enum.any?(allowed_file_send_roots(), &String.starts_with?(expanded, &1))

    unless allowed do
      Logger.warning("[Kyber.Plugin.Discord] send_file blocked — path not in allowed roots: #{expanded}")
      {:error, :path_not_allowed}
    else
      do_send_file(token, channel_id, expanded, opts)
    end
  end

  defp do_send_file(token, channel_id, file_path, opts) do
    url = "#{@discord_api_base}/channels/#{channel_id}/messages"
    headers = [{"Authorization", "Bot #{token}"}]
    content = Keyword.get(opts, :content)

    case File.read(file_path) do
      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] send_file read failed #{file_path}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}

      {:ok, file_content} ->
        send_file_content(url, headers, file_path, file_content, content)
    end
  end

  defp send_file_content(url, headers, file_path, file_content, content) do
    filename = Path.basename(file_path)

    payload_json = if content, do: %{"content" => content}, else: %{}

    form_multipart = [
      {"files[0]", {file_content, filename: filename, content_type: "application/octet-stream"}},
      {"payload_json", Jason.encode!(payload_json)}
    ]

    case Req.post(url, headers: headers, form_multipart: form_multipart) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Kyber.Plugin.Discord] send_file failed: #{status} #{inspect(resp_body)}")
        {:error, %{status: status, body: resp_body}}
      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] send_file HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Update the bot's presence/status. Forwards to Gateway."
  @spec update_presence(GenServer.server(), map()) :: :ok
  def update_presence(server \\ __MODULE__, presence) do
    GenServer.cast(server, {:update_presence, presence})
  end

  @doc """
  Register global slash commands for the bot application.

  Uses bulk-overwrite (PUT) so commands are idempotent on each boot.
  Commands: /ask, /status, /context, /history, /forget
  """
  @spec register_slash_commands(String.t(), String.t()) :: :ok | {:error, term()}
  def register_slash_commands(token, app_id) do
    url = "#{@discord_api_base}/applications/#{app_id}/commands"
    headers = [{"Authorization", "Bot #{token}"}, {"Content-Type", "application/json"}]

    commands = [
      %{
        "name" => "ask",
        "description" => "Ask Kyber a question",
        "options" => [
          %{
            "type" => @option_type_string,
            "name" => "query",
            "description" => "Your question",
            "required" => true
          }
        ]
      },
      %{"name" => "status", "description" => "Get bot status"},
      %{"name" => "context", "description" => "Show current session context"},
      %{"name" => "history", "description" => "Show recent message history"},
      %{"name" => "forget", "description" => "Clear the current session"}
    ]

    case Req.put(url, headers: headers, json: commands) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[Kyber.Plugin.Discord] slash commands registered (#{length(commands)} commands)")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Kyber.Plugin.Discord] slash command registration failed: #{status} #{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] slash command registration error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Build a delta from a Discord INTERACTION_CREATE event (slash command).

  Routes slash commands through the same message.received pipeline.
  The payload carries `interaction_id`, `interaction_token`, and `application_id`
  so the send_message effect handler can respond via the interaction webhook.
  """
  @spec build_interaction_delta(map()) :: Kyber.Delta.t()
  def build_interaction_delta(data) do
    command_name = get_in(data, ["data", "name"]) || ""
    channel_id = data["channel_id"] || "unknown"
    application_id = data["application_id"] || ""
    guild_id = data["guild_id"]

    user = get_in(data, ["member", "user"]) || data["user"] || %{}
    author_id = user["id"] || "unknown"
    username = user["username"]

    text = build_interaction_text(command_name, data)

    payload = %{
      "text" => text,
      "channel_id" => channel_id,
      "author_id" => author_id,
      "guild_id" => guild_id,
      "username" => username,
      "message_id" => nil,
      "attachments" => [],
      "interaction_id" => data["id"],
      "interaction_token" => data["token"],
      "application_id" => application_id,
      "command" => command_name
    }

    Kyber.Delta.new(
      "message.received",
      payload,
      {:channel, "discord", channel_id, author_id}
    )
  end

  @doc """
  Extract Discord embed maps from fenced code blocks in text content.

  Each ```lang\\n...``` block becomes an embed with the language as title
  and the code as a Discord code block in the description.
  Returns an empty list if no code blocks are found.
  """
  @spec extract_code_embeds(String.t() | nil) :: [map()]
  def extract_code_embeds(nil), do: []
  def extract_code_embeds(""), do: []

  def extract_code_embeds(content) when is_binary(content) do
    Regex.scan(@code_block_pattern, content, capture: :all_but_first)
    |> Enum.map(fn
      [lang, code] ->
        title = if lang == "", do: "Code", else: String.upcase(lang)
        trimmed_code = String.slice(code, 0, 3900)
        fence = if lang == "", do: "```", else: "```#{lang}"
        description = "#{fence}\n#{String.trim(trimmed_code)}\n```"
        %{"title" => title, "description" => description, "color" => 0x5865F2}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Parse a raw Discord Gateway message (JSON map) into a structured event."
  @spec parse_gateway_message(map()) :: {:dispatch, String.t(), map()} | {:control, atom()} | :unknown
  def parse_gateway_message(%{"op" => @op_dispatch, "t" => event_type, "d" => data}) do
    {:dispatch, event_type, data}
  end

  def parse_gateway_message(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}}) do
    {:hello, interval}
  end

  def parse_gateway_message(%{"op" => @op_heartbeat_ack}) do
    {:heartbeat_ack}
  end

  def parse_gateway_message(%{"op" => @op_heartbeat}) do
    {:heartbeat}
  end

  def parse_gateway_message(_), do: :unknown

  @doc "Build a delta from a Discord MESSAGE_CREATE event."
  @spec build_message_delta(map()) :: Kyber.Delta.t()
  def build_message_delta(data) do
    channel_id = data["channel_id"] || "unknown"
    author_id = get_in(data, ["author", "id"]) || "unknown"
    content = data["content"] || ""
    guild_id = data["guild_id"]
    author_username = get_in(data, ["author", "username"])

    attachments = extract_attachments(data["attachments"])

    payload = %{
      "text" => content,
      "channel_id" => channel_id,
      "author_id" => author_id,
      "guild_id" => guild_id,
      "username" => author_username,
      "message_id" => data["id"],
      "attachments" => attachments
    }

    Kyber.Delta.new(
      "message.received",
      payload,
      {:channel, "discord", channel_id, author_id}
    )
  end

  @doc """
  Build the JSON body for a Discord message POST.

  ## Options
    * `:reply_to` - message ID to reply to
    * `:embeds` - list of embed maps
  """
  @spec build_message_body(String.t(), keyword()) :: map()
  def build_message_body(content, opts \\ []) do
    body = %{"content" => content}

    body =
      case Keyword.get(opts, :reply_to) do
        nil -> body
        msg_id -> Map.put(body, "message_reference", %{"message_id" => msg_id})
      end

    case Keyword.get(opts, :embeds) do
      nil -> body
      [] -> body
      embeds -> Map.put(body, "embeds", embeds)
    end
  end

  @doc "Split content into <=2000 character chunks, breaking at newlines when possible."
  @spec chunk_message(nil | String.t()) :: [String.t()]
  def chunk_message(nil), do: [""]
  def chunk_message(""), do: [""]

  def chunk_message(content) when is_binary(content) do
    if String.length(content) <= @max_message_length do
      [content]
    else
      do_chunk(content, [])
    end
  end

  @doc "Build the IDENTIFY payload for the Gateway."
  @spec build_identify(String.t()) :: map()
  def build_identify(token) do
    %{
      "op" => @op_identify,
      "d" => %{
        "token" => token,
        "intents" => @gateway_intents,
        "properties" => %{
          "os" => "beam",
          "browser" => "kyber",
          "device" => "kyber"
        }
      }
    }
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    token = get_token(opts)
    core = Keyword.get(opts, :core, Kyber.Core)
    connect = Keyword.get(opts, :connect, Application.get_env(:kyber_beam, :discord_connect, false))

    state = %{
      token: token,
      core: core,
      gateway_pid: nil,
      sequence: nil,
      session_id: nil,
      connected: false,
      application_id: nil,
      bot_user_id: nil
    }

    if token do
      Logger.info("[Kyber.Plugin.Discord] token found, registering effect handlers")
      register_effect_handlers(core, token)

      if connect do
        {:ok, gateway_pid} = Kyber.Plugin.Discord.Gateway.start_link(
          token: token,
          handler_pid: self()
        )
        Process.link(gateway_pid)
        {:ok, %{state | gateway_pid: gateway_pid}}
      else
        Logger.info("[Kyber.Plugin.Discord] discord_connect is false — gateway not started")
        {:ok, state}
      end
    else
      Logger.warning("[Kyber.Plugin.Discord] no DISCORD_BOT_TOKEN set — running without gateway")
      {:ok, state}
    end
  end

  @impl true
  def handle_info({:discord_event, raw_json}, state) do
    with {:ok, msg} <- Jason.decode(raw_json) do
      t = msg["t"]
      # Only log non-noisy events; heartbeat events are handled by Gateway
      if t && t not in ["READY", nil] do
        Logger.debug("[Kyber.Plugin.Discord] event: #{t}")
      end
      state = handle_gateway_message(msg, state)
      {:noreply, state}
    else
      _ ->
        Logger.warning("[Kyber.Plugin.Discord] failed to decode event JSON")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[Kyber.Plugin.Discord] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_presence, presence}, state) do
    if state.gateway_pid && Process.alive?(state.gateway_pid) do
      Kyber.Plugin.Discord.Gateway.send_presence_update(state.gateway_pid, presence)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Kyber.Plugin.Discord] terminating: #{inspect(reason)}")

    if state.gateway_pid && Process.alive?(state.gateway_pid) do
      Process.unlink(state.gateway_pid)
      GenServer.stop(state.gateway_pid, :shutdown)
    end

    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp get_token(opts) do
    Keyword.get(opts, :token) ||
      System.get_env("DISCORD_BOT_TOKEN") ||
      Application.get_env(:kyber_beam, :discord_bot_token)
  end

  defp register_effect_handlers(core, token) do
    send_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"]) ||
                   get_in(effect, ["channel_id"]) ||
                   channel_from_origin(Map.get(effect, :origin))

      content = get_in(effect, [:payload, "content"]) ||
                get_in(effect, [:payload, "text"]) ||
                get_in(effect, ["content"]) || ""

      reply_to = get_in(effect, [:payload, "reply_to"])

      # Slash command interaction context (carried through from INTERACTION_CREATE delta)
      interaction_token = get_in(effect, [:payload, "interaction_token"])
      application_id = get_in(effect, [:payload, "application_id"])

      # Embed support: explicit embeds in payload OR auto-extracted from code blocks
      explicit_embeds = get_in(effect, [:payload, "embeds"])
      code_embeds = if is_nil(explicit_embeds), do: extract_code_embeds(content), else: []
      embeds = explicit_embeds || (if code_embeds != [], do: code_embeds, else: nil)

      # File/image sending: list of file paths in the effect payload
      files = get_in(effect, [:payload, "files"]) || []

      opts = []
      opts = if reply_to, do: Keyword.put(opts, :reply_to, reply_to), else: opts
      opts = if embeds, do: Keyword.put(opts, :embeds, embeds), else: opts

      cond do
        # Slash command: respond via interaction webhook (supports 15min window)
        is_binary(interaction_token) && is_binary(application_id) && application_id != "" ->
          send_interaction_followup(token, application_id, interaction_token, content, opts)

        # Files: multipart upload (first file carries the content caption)
        files != [] && is_binary(channel_id) ->
          [first_file | rest_files] = files
          result = send_file(token, channel_id, first_file, content: if(content != "", do: content, else: nil))
          Enum.each(rest_files, fn f -> send_file(token, channel_id, f) end)
          result

        # Regular channel message
        is_binary(channel_id) && (content != "" || embeds) ->
          send_message(token, channel_id, content, opts)

        true ->
          Logger.warning("[Kyber.Plugin.Discord] send_message effect missing channel_id or content")
          {:error, :missing_params}
      end
    end

    typing_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"]) ||
                   channel_from_origin(Map.get(effect, :origin))

      if channel_id, do: send_typing(token, channel_id), else: {:error, :missing_channel_id}
    end

    add_reaction_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])
      emoji = get_in(effect, [:payload, "emoji"])

      if channel_id && message_id && emoji do
        add_reaction(token, channel_id, message_id, emoji)
      else
        {:error, :missing_params}
      end
    end

    remove_reaction_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])
      emoji = get_in(effect, [:payload, "emoji"])

      if channel_id && message_id && emoji do
        remove_reaction(token, channel_id, message_id, emoji)
      else
        {:error, :missing_params}
      end
    end

    edit_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])
      content = get_in(effect, [:payload, "content"])

      if channel_id && message_id && content do
        edit_message(token, channel_id, message_id, content)
      else
        {:error, :missing_params}
      end
    end

    delete_handler = fn effect ->
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])

      if channel_id && message_id do
        delete_message(token, channel_id, message_id)
      else
        Logger.warning("[Kyber.Plugin.Discord] delete_message effect missing channel_id or message_id")
        {:error, :missing_params}
      end
    end

    handlers = [
      {:send_message, send_handler},
      {:send_typing, typing_handler},
      {:add_reaction, add_reaction_handler},
      {:remove_reaction, remove_reaction_handler},
      {:edit_message, edit_handler},
      {:delete_message, delete_handler}
    ]

    try do
      for {type, handler} <- handlers do
        Kyber.Core.register_effect_handler(core, type, handler)
      end

      Logger.info("[Kyber.Plugin.Discord] effect handlers registered: #{inspect(Enum.map(handlers, &elem(&1, 0)))}")
    catch
      :exit, reason ->
        Logger.warning("[Kyber.Plugin.Discord] could not register handlers (core not ready): #{inspect(reason)}")
      kind, reason ->
        Logger.error("[Kyber.Plugin.Discord] failed to register handlers: #{kind} #{inspect(reason)}")
    end
  end

  # Protocol-level opcodes (HELLO, HEARTBEAT_ACK) are handled by Gateway.
  # Discord plugin only cares about application-level events.

  defp handle_gateway_message(%{"op" => @op_hello}, state) do
    # Gateway handles HELLO/IDENTIFY/heartbeat — no-op here
    state
  end

  defp handle_gateway_message(%{"op" => @op_heartbeat_ack}, state) do
    # Gateway handles heartbeat acks — no-op here
    state
  end

  defp handle_gateway_message(%{"op" => @op_dispatch, "t" => "READY", "d" => data, "s" => seq}, state) do
    session_id = data["session_id"]
    application_id = get_in(data, ["application", "id"])
    bot_user_id = get_in(data, ["user", "id"])
    Logger.info("[Kyber.Plugin.Discord] READY — session_id: #{session_id}, app_id: #{application_id}, bot_user_id: #{bot_user_id}")

    # Register slash commands in the background (non-blocking)
    if application_id && state.token do
      token = state.token
      Task.start(fn -> register_slash_commands(token, application_id) end)
    end

    %{state | session_id: session_id, sequence: seq, application_id: application_id, bot_user_id: bot_user_id}
  end

  # Liet's bot ID — treat as a peer, not a bot to ignore
  @liet_user_id "1466660860582821995"

  defp handle_gateway_message(%{"op" => @op_dispatch, "t" => "MESSAGE_CREATE", "d" => data, "s" => seq}, state) do
    author_id = get_in(data, ["author", "id"]) || ""
    is_bot = get_in(data, ["author", "bot"]) || false
    content = data["content"] || ""
    guild_id = data["guild_id"]

    # Ignore our own messages. Allow Liet (sibling bot). Ignore other bots.
    bot_user_id = state.bot_user_id
    is_self = bot_user_id != nil && author_id == bot_user_id
    is_liet = author_id == @liet_user_id
    skip = is_self || (is_bot && !is_liet)

    if skip do
      %{state | sequence: seq}
    else
      # Respond to @mentions (user or role), DMs, or replies to our messages
      is_dm = is_nil(guild_id)
      is_mentioned = bot_user_id != nil && (String.contains?(content, "<@#{bot_user_id}>") or String.contains?(content, "<@!#{bot_user_id}>"))
      mention_roles = data["mention_roles"] || []
      is_role_mentioned = Enum.any?(mention_roles, fn role_id ->
        # Check if any of our roles were mentioned (role mentions use <@&ROLE_ID>)
        String.contains?(content, "<@&#{role_id}>")
      end)
      is_reply_to_us = bot_user_id != nil && get_in(data, ["referenced_message", "author", "id"]) == bot_user_id

      if is_dm or is_mentioned or is_role_mentioned or is_reply_to_us do
        delta = build_message_delta(data)
        Logger.debug("[Kyber.Plugin.Discord] emitting message.received delta: #{delta.id}")
        try do
          Kyber.Core.emit(state.core, delta)
        rescue
          e -> Logger.error("[Kyber.Plugin.Discord] failed to emit delta: #{inspect(e)}")
        end
      else
        Logger.debug("[Kyber.Plugin.Discord] ignoring message (no mention, not DM)")
      end

      %{state | sequence: seq}
    end
  end

  defp handle_gateway_message(%{"op" => @op_dispatch, "t" => "INTERACTION_CREATE", "d" => data, "s" => seq}, state) do
    if data["type"] == @interaction_type_application_command do
      command_name = get_in(data, ["data", "name"]) || "unknown"
      Logger.debug("[Kyber.Plugin.Discord] slash command: /#{command_name}")

      # Immediately ACK the interaction to avoid Discord's 3-second timeout.
      # Type 5 = DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE ("bot is thinking...")
      respond_interaction(state.token, data["id"], data["token"])

      delta = build_interaction_delta(data)

      try do
        Kyber.Core.emit(state.core, delta)
      rescue
        e -> Logger.error("[Kyber.Plugin.Discord] failed to emit interaction delta: #{inspect(e)}")
      end
    end

    %{state | sequence: seq}
  end

  defp handle_gateway_message(%{"op" => @op_dispatch, "s" => seq}, state) when not is_nil(seq) do
    %{state | sequence: seq}
  end

  defp handle_gateway_message(_msg, state) do
    state
  end

  defp channel_from_origin({:channel, "discord", channel_id, _}), do: channel_id
  defp channel_from_origin(_), do: nil

  defp post_message(token, channel_id, body) do
    url = "#{@discord_api_base}/channels/#{channel_id}/messages"
    headers = [{"Authorization", "Bot #{token}"}, {"Content-Type", "application/json"}]

    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Kyber.Plugin.Discord] send_message failed: #{status} #{inspect(resp_body)}")
        {:error, %{status: status, body: resp_body}}
      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] send_message HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_chunk("", acc), do: Enum.reverse(acc)

  defp do_chunk(content, acc) do
    if String.length(content) <= @max_message_length do
      Enum.reverse([content | acc])
    else
      window = String.slice(content, 0, @max_message_length)

      case String.split(window, "\n") do
        [_no_newlines] ->
          # No newline found — hard break at max length
          rest = String.slice(content, @max_message_length, String.length(content))
          do_chunk(rest, [window | acc])

        lines ->
          # Drop the last (potentially incomplete) line, keep complete lines
          chunk_lines = Enum.drop(lines, -1)
          chunk = Enum.join(chunk_lines, "\n")

          if chunk == "" do
            # Newline only at position 0 — hard break
            rest = String.slice(content, @max_message_length, String.length(content))
            do_chunk(rest, [window | acc])
          else
            rest = String.slice(content, String.length(chunk) + 1, String.length(content))
            do_chunk(rest, [chunk | acc])
          end
      end
    end
  end

  @attachment_fields ~w(id filename content_type size url proxy_url width height)

  defp extract_attachments(nil), do: []
  defp extract_attachments([]), do: []

  defp extract_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn att ->
      Map.take(att, @attachment_fields)
    end)
  end

  # ── Private: Slash command helpers ────────────────────────────────────────

  # Build the text prompt for each slash command to feed into the delta pipeline.
  defp build_interaction_text("ask", data) do
    options = get_in(data, ["data", "options"]) || []
    Enum.find_value(options, "", fn opt ->
      if opt["name"] == "query", do: opt["value"], else: nil
    end)
  end

  defp build_interaction_text("status", _data), do: "What is your current status?"
  defp build_interaction_text("context", _data), do: "What is our current session context?"
  defp build_interaction_text("history", _data), do: "Show me our recent message history."
  defp build_interaction_text("forget", _data), do: "Please clear our session history and start fresh."
  defp build_interaction_text(name, _data), do: "Execute command: /#{name}"

  # Send an immediate deferred ACK for an interaction (type 5 = "bot is thinking...")
  defp respond_interaction(nil, _interaction_id, _interaction_token), do: :ok

  defp respond_interaction(token, interaction_id, interaction_token) do
    url = "#{@discord_api_base}/interactions/#{interaction_id}/#{interaction_token}/callback"
    headers = [{"Authorization", "Bot #{token}"}, {"Content-Type", "application/json"}]
    body = %{"type" => @interaction_response_deferred_channel_message}

    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Kyber.Plugin.Discord] interaction ACK failed: #{status} #{inspect(resp_body)}")
        {:error, %{status: status, body: resp_body}}
      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] interaction ACK error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Send a followup message to an already-deferred interaction via webhook.
  # Must be called within 15 minutes of the original interaction.
  defp send_interaction_followup(token, application_id, interaction_token, content, opts) do
    url = "#{@discord_api_base}/webhooks/#{application_id}/#{interaction_token}"
    headers = [{"Authorization", "Bot #{token}"}, {"Content-Type", "application/json"}]

    embeds = Keyword.get(opts, :embeds)
    body = %{"content" => content}
    body = if embeds && embeds != [], do: Map.put(body, "embeds", embeds), else: body

    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[Kyber.Plugin.Discord] interaction followup failed: #{status} #{inspect(resp_body)}")
        {:error, %{status: status, body: resp_body}}
      {:error, reason} ->
        Logger.error("[Kyber.Plugin.Discord] interaction followup error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Directories from which send_file is permitted to read.
  # Evaluated at runtime so Path.expand and System.tmp_dir! use the actual
  # $HOME, not the build environment. Also includes /tmp and /private/tmp
  # since macOS /tmp symlinks to /private/tmp but System.tmp_dir! returns
  # /var/folders/...
  defp allowed_file_send_roots do
    [
      Path.expand("~/.kyber"),
      Path.expand("~/kyber-beam"),
      System.tmp_dir!(),
      "/tmp",
      "/private/tmp"
    ]
  end
end
