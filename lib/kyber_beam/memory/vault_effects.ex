defmodule Kyber.Memory.VaultEffects do
  @moduledoc """
  Effect handlers for `:vault_write` and `:vault_delete` effects.

  These handlers bridge the delta pipeline to the Knowledge vault:
  - `:vault_write` → `Kyber.Knowledge.put_note/4` → emits `"vault.written"` delta
  - `:vault_delete` → `Kyber.Knowledge.delete_note/2` → emits `"vault.deleted"` delta

  ## Registration

  Call `register/2` after Core and Knowledge are both started:

      Kyber.Memory.VaultEffects.register(core, knowledge_server)

  Or use `register/1` which defaults to `Kyber.Knowledge`:

      Kyber.Memory.VaultEffects.register(core)
  """

  require Logger

  @doc """
  Register `:vault_write` and `:vault_delete` effect handlers with the given Core.
  """
  @spec register(Supervisor.supervisor(), GenServer.server()) :: :ok
  def register(core, knowledge_server \\ Kyber.Knowledge) do
    register_vault_write(core, knowledge_server)
    register_vault_delete(core, knowledge_server)
    Logger.info("[Kyber.Memory.VaultEffects] registered vault_write and vault_delete handlers")
    :ok
  end

  defp register_vault_write(core, knowledge_server) do
    Kyber.Core.register_effect_handler(core, :vault_write, fn effect ->
      path = Map.get(effect, :path, "")
      content = Map.get(effect, :content, "")
      reason = Map.get(effect, :reason, "")

      Logger.info("[VaultEffects] vault_write: #{path} (reason: #{reason})")

      # Write to vault via Knowledge — content is the body, reason goes in frontmatter
      frontmatter = %{"reason" => reason, "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

      case Kyber.Knowledge.put_note(knowledge_server, path, frontmatter, content) do
        :ok ->
          # Emit confirmation delta
          confirmation = Kyber.Delta.new("vault.written", %{
            "path" => path,
            "ts" => System.system_time(:millisecond)
          })

          try do
            Kyber.Core.emit(core, confirmation)
          rescue
            e -> Logger.error("[VaultEffects] failed to emit vault.written: #{inspect(e)}")
          end

          :ok

        {:error, reason} ->
          Logger.error("[VaultEffects] vault_write failed for #{path}: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  defp register_vault_delete(core, knowledge_server) do
    Kyber.Core.register_effect_handler(core, :vault_delete, fn effect ->
      path = Map.get(effect, :path, "")
      reason = Map.get(effect, :reason, "")

      Logger.info("[VaultEffects] vault_delete: #{path} (reason: #{reason})")

      case Kyber.Knowledge.delete_note(knowledge_server, path) do
        :ok ->
          # Emit confirmation delta
          confirmation = Kyber.Delta.new("vault.deleted", %{
            "path" => path,
            "reason" => reason,
            "ts" => System.system_time(:millisecond)
          })

          try do
            Kyber.Core.emit(core, confirmation)
          rescue
            e -> Logger.error("[VaultEffects] failed to emit vault.deleted: #{inspect(e)}")
          end

          :ok

        {:error, :not_found} ->
          Logger.warning("[VaultEffects] vault_delete: #{path} not found (already deleted?)")
          :ok
      end
    end)
  end
end
