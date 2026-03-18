defmodule Kyber.Familiard do
  @moduledoc """
  Familiard daemon integration stub for Kyber.

  The familiard is an external daemon that monitors processes, memory, and
  system health, escalating events when thresholds are exceeded. This module
  is a lightweight stub that:

  1. Accepts HTTP webhooks at `POST /api/familiard/escalate`
  2. Parses escalation events and emits `"familiard.escalation"` deltas
  3. Can poll familiard's health endpoint via `get_status/0`

  The full familiard implementation lives in a separate repo.

  ## Config

      config :kyber_beam, Kyber.Familiard,
        endpoint: "http://localhost:8765",  # familiard HTTP endpoint
        enabled: true,
        webhook_secret: "my_shared_secret" # optional HMAC-SHA256 signing key

  ## Webhook Signature Validation

  When `webhook_secret` is configured, incoming webhooks must include an
  `x-familiard-signature` header containing the HMAC-SHA256 hex digest of the
  raw request body, keyed with the shared secret.

  If no secret is configured, all requests are accepted (dev mode) and a
  warning is logged on startup.

  Use `Kyber.Familiard.verify_signature/3` in your webhook controller:

      case Kyber.Familiard.verify_signature(familiard_pid, raw_body, signature_header) do
        :ok -> # proceed
        {:error, :invalid_signature} -> # reject 401
        {:error, :no_secret} -> :ok    # dev mode, pass through
      end

  ## Webhook payload format

      {
        "level": "warning",          # "info" | "warning" | "critical"
        "message": "High memory",
        "context": {"memory_mb": 4200, "process": "my_app"},
        "timestamp": "2025-01-15T09:30:00Z"
      }
  """

  use GenServer
  require Logger

  @default_endpoint "http://localhost:8765"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Verify a webhook request signature.

  Computes HMAC-SHA256 of `raw_body` with the server's configured secret and
  compares it (in constant time) against `signature` (a hex string).

  Returns:
  - `:ok` — signature valid
  - `{:error, :invalid_signature}` — signature mismatch
  - `{:error, :no_secret}` — no secret configured (dev mode)
  """
  @spec verify_signature(GenServer.server(), binary(), String.t() | nil) ::
          :ok | {:error, :invalid_signature | :no_secret}
  def verify_signature(server \\ __MODULE__, raw_body, signature) do
    GenServer.call(server, {:verify_signature, raw_body, signature})
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Parse an escalation webhook payload and return a structured event map.

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec parse_escalation(map()) :: {:ok, map()} | {:error, term()}
  def parse_escalation(payload) when is_map(payload) do
    with {:ok, level} <- validate_level(Map.get(payload, "level")),
         {:ok, message} <- validate_message(Map.get(payload, "message")) do
      event = %{
        level: level,
        message: message,
        context: Map.get(payload, "context", %{}),
        timestamp: Map.get(payload, "timestamp", DateTime.to_iso8601(DateTime.utc_now()))
      }

      {:ok, event}
    end
  end

  def parse_escalation(_), do: {:error, :invalid_payload}

  @doc """
  Emit an escalation event as a Kyber delta.

  Called by the webhook handler after parsing.
  """
  @spec emit_escalation(GenServer.server(), map()) :: :ok
  def emit_escalation(server \\ __MODULE__, event) do
    GenServer.call(server, {:emit_escalation, event})
  end

  @doc """
  Poll familiard's health endpoint and return its status.

  Returns `{:ok, status_map}` or `{:error, reason}`.
  """
  @spec get_status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status, 10_000)
  end

  @doc "Get the configured familiard endpoint URL."
  @spec endpoint(GenServer.server()) :: String.t()
  def endpoint(server \\ __MODULE__) do
    GenServer.call(server, :get_endpoint)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    core = Keyword.get(opts, :core, nil)

    app_config = Application.get_env(:kyber_beam, Kyber.Familiard, [])

    endpoint_url =
      Keyword.get(opts, :endpoint) ||
      Keyword.get(app_config, :endpoint, @default_endpoint)

    webhook_secret =
      Keyword.get(opts, :webhook_secret) ||
      Keyword.get(app_config, :webhook_secret, nil)

    if is_nil(webhook_secret) do
      Logger.warning(
        "[Kyber.Familiard] no webhook_secret configured — " <>
          "accepting all webhook requests without signature validation (dev mode)"
      )
    end

    state = %{
      core: core,
      endpoint: endpoint_url,
      webhook_secret: webhook_secret
    }

    Logger.info("[Kyber.Familiard] stub initialized (endpoint: #{endpoint_url})")
    {:ok, state}
  end

  @impl true
  def handle_call({:emit_escalation, event}, _from, state) do
    if state.core do
      delta = Kyber.Delta.new(
        "familiard.escalation",
        %{
          "level" => to_string(event.level),
          "message" => event.message,
          "context" => event.context,
          "timestamp" => event.timestamp
        },
        {:system, "familiard"}
      )

      try do
        Kyber.Core.emit(state.core, delta)
      rescue
        e -> Logger.error("[Kyber.Familiard] failed to emit escalation delta: #{inspect(e)}")
      end
    end

    {:reply, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    result = poll_familiard_status(state.endpoint)
    {:reply, result, state}
  end

  def handle_call(:get_endpoint, _from, state) do
    {:reply, state.endpoint, state}
  end

  def handle_call({:verify_signature, _raw_body, _signature}, _from, %{webhook_secret: nil} = state) do
    {:reply, {:error, :no_secret}, state}
  end

  def handle_call({:verify_signature, raw_body, signature}, _from, state) do
    expected =
      :crypto.mac(:hmac, :sha256, state.webhook_secret, raw_body)
      |> Base.encode16(case: :lower)

    # Constant-time comparison to prevent timing attacks
    result =
      if secure_compare(expected, to_string(signature || "")) do
        :ok
      else
        {:error, :invalid_signature}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  defp poll_familiard_status(endpoint) do
    health_url = "#{endpoint}/health"

    case Req.get(health_url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, map} -> {:ok, map}
          _ -> {:ok, %{"status" => "ok", "raw" => body}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Constant-time string comparison to mitigate timing attacks on HMAC validation.
  defp secure_compare(a, b) when byte_size(a) != byte_size(b), do: false

  defp secure_compare(a, b) do
    :crypto.hash_equals(a, b)
  end

  defp validate_level(level) when level in ["info", "warning", "critical"],
    do: {:ok, String.to_atom(level)}

  defp validate_level(nil), do: {:error, :missing_level}
  defp validate_level(_), do: {:error, :invalid_level}

  defp validate_message(msg) when is_binary(msg) and msg != "", do: {:ok, msg}
  defp validate_message(nil), do: {:error, :missing_message}
  defp validate_message(_), do: {:error, :invalid_message}
end
