import Config

# Vault path for memory_read / memory_write / memory_list tools.
# Override in config/test.exs or config/runtime.exs.
config :kyber_beam, :vault_path, Path.expand("~/.kyber/vault")

# LLM model selection. Override in config/runtime.exs or via environment.
# Example: config :kyber_beam, :model, "claude-opus-4-20250514"
config :kyber_beam, :model, "claude-sonnet-4-20250514"

# LLM rate limiting: maximum API calls per minute (P3-6).
# Override in runtime.exs or environment-specific configs.
config :kyber_beam, :max_llm_calls_per_minute, 30

# Enable SSE streaming for LLM responses (P3-1).
# When true, uses Anthropic's streaming API and emits llm.stream_chunk deltas.
# Falls back to synchronous call on streaming failure.
config :kyber_beam, :llm_streaming, true

# Enable extended thinking for LLM responses (P3-1b).
# When true, Anthropic's extended thinking feature is requested (explicit opt-in required).
# temperature must not be set when thinking is enabled — it is stripped automatically.
config :kyber_beam, :llm_thinking, true
config :kyber_beam, :thinking_budget_tokens, 10_000

# Token budget for context window management (P3-7).
# Anthropic claude-sonnet/opus have a 200K token window; we reserve 20K for the
# model's response, leaving 180K for the conversation history + system prompt.
config :kyber_beam, :max_context_tokens, 180_000

# Phoenix Endpoint for LiveView Dashboard (port 4001)
config :kyber_beam, Kyber.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4001],
  url: [host: "0.0.0.0"],
  # secret_key_base is NOT set here — env-specific configs set it explicitly.
  # prod.exs requires SECRET_KEY_BASE env var (raises if missing).
  # dev.exs sets a dev-only placeholder.
  # Never put a fallback value here — it would be used if prod.exs fails to override.
  live_view: [signing_salt: "kyber_lv_salt"],
  pubsub_server: Kyber.PubSub,
  render_errors: [formats: [html: Kyber.Web.ErrorHTML], layout: false],
  server: true

# PubSub
config :kyber_beam, Kyber.PubSub,
  name: Kyber.PubSub

import_config "#{config_env()}.exs"
