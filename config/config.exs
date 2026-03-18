import Config

# Phoenix Endpoint for LiveView Dashboard (port 4001)
config :kyber_beam, Kyber.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4001],
  url: [host: "localhost"],
  secret_key_base: "kyber_beam_secret_key_base_at_least_64_chars_long_for_security_dev",
  live_view: [signing_salt: "kyber_lv_salt"],
  pubsub_server: Kyber.PubSub,
  render_errors: [formats: [html: Kyber.Web.ErrorHTML], layout: false],
  server: true

# PubSub
config :kyber_beam, Kyber.PubSub,
  name: Kyber.PubSub

import_config "#{config_env()}.exs"
