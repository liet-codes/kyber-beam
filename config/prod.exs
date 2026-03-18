import Config

config :kyber_beam, Kyber.Web.Endpoint,
  server: true,
  secret_key_base: System.get_env("SECRET_KEY_BASE") ||
    raise("Missing SECRET_KEY_BASE env var")
