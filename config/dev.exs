import Config

config :kyber_beam,
  start_web: true,
  port: 4000,
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  discord_connect: System.get_env("DISCORD_BOT_TOKEN") != nil

config :kyber_beam, Kyber.Web.Endpoint,
  server: true,
  debug_errors: true,
  check_origin: false
