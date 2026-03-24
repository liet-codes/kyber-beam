import Config

# Don't start the Phoenix server in tests
config :kyber_beam, Kyber.Web.Endpoint,
  server: false

# Use a separate data dir in tests to avoid polluting priv/data
config :kyber_beam, :data_dir, "test/tmp"

# Use a temp vault path in tests to avoid touching ~/.kyber/vault
config :kyber_beam, :vault_path, Path.join(System.tmp_dir!(), "kyber_test_vault")

# Use test-specific sentinel paths for camera_snap so the real
# com.liet.snap-watcher daemon (which watches /tmp/snap_request) cannot
# intercept test requests and corrupt expected error/timeout scenarios.
config :kyber_beam, :snap_request_path, "/tmp/kyber_test_snap_request"
config :kyber_beam, :snap_result_path, "/tmp/kyber_test_snap_result"
