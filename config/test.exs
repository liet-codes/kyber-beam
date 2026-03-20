import Config

# Don't start the Phoenix server in tests
config :kyber_beam, Kyber.Web.Endpoint,
  server: false

# Use a separate data dir in tests to avoid polluting priv/data
config :kyber_beam, :data_dir, "test/tmp"

# Use a temp vault path in tests to avoid touching ~/.kyber/vault
config :kyber_beam, :vault_path, Path.join(System.tmp_dir!(), "kyber_test_vault")
