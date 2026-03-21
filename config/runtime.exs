import Config

# Allow the vault path to be overridden at runtime via KYBER_VAULT_PATH.
# Falls back to the compile-time default (~/.kyber/vault) if not set.
if vault_path = System.get_env("KYBER_VAULT_PATH") do
  config :kyber_beam, :vault_path, vault_path
end
