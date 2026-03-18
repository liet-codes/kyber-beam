import Config

# Don't start the Phoenix server in tests
config :kyber_beam, Kyber.Web.Endpoint,
  server: false

# Use a separate data dir in tests to avoid polluting priv/data
config :kyber_beam, :data_dir, "test/tmp"
