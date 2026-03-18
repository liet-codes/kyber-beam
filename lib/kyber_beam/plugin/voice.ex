defmodule Kyber.Plugin.Voice do
  @moduledoc """
  ElevenLabs TTS integration as a Kyber plugin.

  Registers a `:speak` effect handler with `Kyber.Core`. When fired, it
  sends text to ElevenLabs and emits a `"voice.audio"` delta with the
  raw audio bytes (MP3) encoded as Base64 in the payload.

  ## v3 Audio Tags

  ElevenLabs v3 supports inline audio direction tags like `[happy]`, `[whisper]`,
  `[dramatic]`, etc. These are passed through as-is — ElevenLabs handles them.

  ## Config

      config :kyber_beam, Kyber.Plugin.Voice,
        api_key: "sk_...",          # or set ELEVENLABS_API_KEY env var
        default_voice_id: "...",    # voice to use when none specified
        default_model: "eleven_v3"  # defaults to eleven_v3

  ## Effect format

      %{
        type: :speak,
        payload: %{
          "text" => "Hello world [excited]",
          "voice_id" => "optional_voice_id",  # overrides default
          "model_id" => "eleven_v3"            # optional override
        }
      }
  """

  use GenServer
  require Logger

  @elevenlabs_url "https://api.elevenlabs.io/v1/text-to-speech"
  @default_model "eleven_v3"
  @default_voice_id "6OBKYcAOcB3NNsCq3WHx"

  @voice_settings %{
    "stability" => 0.5,
    "similarity_boost" => 0.75,
    "style" => 0.0,
    "use_speaker_boost" => true
  }

  # ── Plugin behaviour ──────────────────────────────────────────────────────

  def name, do: "voice"

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Speak text via ElevenLabs TTS.

  Returns `{:ok, audio_bytes}` or `{:error, reason}`.
  """
  @spec speak(GenServer.server(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def speak(server \\ __MODULE__, text, opts \\ []) do
    GenServer.call(server, {:speak, text, opts}, 30_000)
  end

  @doc "Get current config."
  @spec get_config(GenServer.server()) :: map()
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    core = Keyword.get(opts, :core, Kyber.Core)

    app_config = Application.get_env(:kyber_beam, Kyber.Plugin.Voice, [])

    api_key =
      Keyword.get(opts, :api_key) ||
      Keyword.get(app_config, :api_key) ||
      System.get_env("ELEVENLABS_API_KEY")

    default_voice_id =
      Keyword.get(opts, :default_voice_id) ||
      Keyword.get(app_config, :default_voice_id, @default_voice_id)

    default_model =
      Keyword.get(opts, :default_model) ||
      Keyword.get(app_config, :default_model, @default_model)

    state = %{
      core: core,
      api_key: api_key,
      default_voice_id: default_voice_id,
      default_model: default_model
    }

    if api_key do
      Logger.info("[Kyber.Plugin.Voice] initialized (voice: #{default_voice_id}, model: #{default_model})")
      send(self(), :register_handlers)
    else
      Logger.warning("[Kyber.Plugin.Voice] no API key configured — TTS disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:register_handlers, state) do
    register_effect_handler(state)
    Logger.info("[Kyber.Plugin.Voice] :speak effect handler registered")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:speak, text, opts}, _from, state) do
    voice_id = Keyword.get(opts, :voice_id, state.default_voice_id)
    model_id = Keyword.get(opts, :model_id, state.default_model)

    result = call_elevenlabs(state.api_key, text, voice_id, model_id)
    {:reply, result, state}
  end

  def handle_call(:get_config, _from, state) do
    {:reply, Map.take(state, [:default_voice_id, :default_model]), state}
  end

  def handle_call(:get_api_key, _from, state) do
    {:reply, state.api_key, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp register_effect_handler(%{core: core}) do
    plugin_pid = self()

    handler = fn effect ->
      api_key = GenServer.call(plugin_pid, :get_api_key)
      config = GenServer.call(plugin_pid, :get_config)
      handle_speak_effect(effect, core, api_key, config)
    end

    try do
      Kyber.Core.register_effect_handler(core, :speak, handler)
    catch
      :exit, reason ->
        Logger.warning("[Kyber.Plugin.Voice] could not register handler: #{inspect(reason)}")
    end
  end

  defp handle_speak_effect(effect, core, api_key, config) do
    payload = Map.get(effect, :payload, %{})
    text = Map.get(payload, "text", "")
    voice_id = Map.get(payload, "voice_id") || config.default_voice_id
    model_id = Map.get(payload, "model_id") || config.default_model
    parent_id = Map.get(effect, :delta_id)
    origin = Map.get(effect, :origin, {:system, "voice"})

    case api_key do
      nil ->
        emit_error(core, "no ElevenLabs API key configured", origin, parent_id)

      key ->
        case call_elevenlabs(key, text, voice_id, model_id) do
          {:ok, audio_bytes} ->
            delta = Kyber.Delta.new(
              "voice.audio",
              %{
                "audio" => Base.encode64(audio_bytes),
                "encoding" => "mp3",
                "voice_id" => voice_id,
                "model_id" => model_id
              },
              {:subagent, parent_id || "voice"},
              parent_id
            )

            try do
              Kyber.Core.emit(core, delta)
            rescue
              e -> Logger.error("[Kyber.Plugin.Voice] failed to emit delta: #{inspect(e)}")
            end

          {:error, reason} ->
            emit_error(core, inspect(reason), origin, parent_id)
        end
    end
  end

  @doc false
  def call_elevenlabs(api_key, text, voice_id, model_id) do
    url = "#{@elevenlabs_url}/#{voice_id}"

    body = %{
      "text" => text,
      "model_id" => model_id,
      "voice_settings" => @voice_settings
    }

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"}
    ]

    case Req.post(url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: audio_bytes}} when is_binary(audio_bytes) ->
        {:ok, audio_bytes}

      {:ok, %{status: status, body: body}} ->
        error_msg =
          cond do
            is_map(body) -> get_in(body, ["detail", "message"]) || inspect(body)
            is_binary(body) -> body
            true -> "HTTP #{status}"
          end

        {:error, %{status: status, message: error_msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_error(core, message, origin, parent_id) do
    delta = Kyber.Delta.new(
      "voice.error",
      %{"error" => message},
      origin || {:system, "voice"},
      parent_id
    )

    try do
      Kyber.Core.emit(core, delta)
    rescue
      e -> Logger.error("[Kyber.Plugin.Voice] failed to emit error: #{inspect(e)}")
    end
  end
end
