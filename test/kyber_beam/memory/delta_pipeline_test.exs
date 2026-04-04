defmodule Kyber.Memory.DeltaPipelineTest do
  @moduledoc """
  End-to-end tests for the delta-routed memory write pipeline.

  Verifies the full chain:
    memory.add delta → reducer → vault_write effect → Knowledge.put_note → file on disk
    memory.delete delta → reducer → vault_delete effect → Knowledge.delete_note → file removed
  """
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta, Knowledge}

  setup do
    vault_dir = Path.join(System.tmp_dir!(), "kyber_delta_pipeline_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(vault_dir)
    File.mkdir_p!(vault_dir)

    store_path = Path.join(System.tmp_dir!(), "delta_pipeline_test_#{System.unique_integer([:positive])}.jsonl")

    # Start a dedicated Core with isolated names
    core_name = :"DeltaPipelineTest_#{System.unique_integer([:positive])}"
    knowledge_name = :"#{core_name}.Knowledge"

    {:ok, knowledge} =
      Knowledge.start_link(
        name: knowledge_name,
        vault_path: vault_dir
      )

    {:ok, core} =
      Core.start_link(
        name: core_name,
        store_path: store_path,
        plugins: []
      )

    # Register the vault effect handlers using our VaultEffects module
    Kyber.Memory.VaultEffects.register(core_name, knowledge_name)

    on_exit(fn ->
      # Cleanup — stop processes safely
      try do
        if Process.alive?(core), do: Supervisor.stop(core, :normal, 5000)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(knowledge), do: GenServer.stop(knowledge, :normal, 5000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(vault_dir)
      File.rm(store_path)
    end)

    %{core: core, core_name: core_name, knowledge: knowledge, vault_dir: vault_dir}
  end

  test "memory.add delta flows through pipeline and writes file to vault", ctx do
    delta = Delta.new("memory.add", %{
      "path" => "people/myk.md",
      "content" => "# Myk\nSoftware engineer in Ohio.",
      "reason" => "Extracted from conversation"
    })

    Core.emit(ctx.core_name, delta)

    # Wait for async pipeline to process
    Process.sleep(500)

    # Verify file exists in vault
    file_path = Path.join(ctx.vault_dir, "people/myk.md")
    assert File.exists?(file_path), "Expected vault file to exist at #{file_path}"

    content = File.read!(file_path)
    assert content =~ "Myk"
    assert content =~ "Software engineer"
  end

  test "memory.delete delta flows through pipeline and removes file from vault", ctx do
    # First, create a file via Knowledge directly
    :ok = Knowledge.put_note(ctx.knowledge, "people/old-contact.md", %{}, "# Old\nStale contact.")

    # Verify it exists
    file_path = Path.join(ctx.vault_dir, "people/old-contact.md")
    assert File.exists?(file_path)

    # Now delete via delta
    delta = Delta.new("memory.delete", %{
      "path" => "people/old-contact.md",
      "reason" => "No longer relevant"
    })

    Core.emit(ctx.core_name, delta)

    # Wait for async pipeline
    Process.sleep(500)

    # File should be gone
    refute File.exists?(file_path), "Expected vault file to be deleted"
  end
end
