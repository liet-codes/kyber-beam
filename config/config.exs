import Config

# Vault path for memory_read / memory_write / memory_list tools.
# Override in config/test.exs or config/runtime.exs.
config :kyber_beam, :vault_path, Path.expand("~/.kyber/vault")

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
