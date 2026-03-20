import Config

config :kyber_beam,
  start_web: true,
  port: 4000,
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  discord_connect: System.get_env("DISCORD_BOT_TOKEN") != nil

config :kyber_beam, Kyber.Web.Endpoint,
  server: true,
  debug_errors: true,
  check_origin: false,
  # Dev-only placeholder — safe to have in source because prod.exs overrides it.
  secret_key_base: "kyber_beam_dev_only_secret_key_base_at_least_64_chars_long_for_security!!"
