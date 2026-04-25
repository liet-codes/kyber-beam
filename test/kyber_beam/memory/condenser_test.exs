defmodule Kyber.Memory.CondenserTest do
  @moduledoc """
  Verifies the Memory Condenser write path:

      llm.response delta
        → Condenser handle_info
        → File written to vault
        → memory.condensed delta emitted (assert_receive)

  No `Process.sleep/1` — synchronization is via `assert_receive` on the
  `memory.condensed` delta. Because the file is written **before** the
  delta is emitted, observing the delta proves the file is on disk.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta, Knowledge}
  alias Kyber.Memory.Condenser

  setup do
    suffix = System.unique_integer([:positive])

    vault_dir = Path.join(System.tmp_dir!(), "kyber_condenser_test_#{suffix}")
    File.rm_rf!(vault_dir)
    File.mkdir_p!(vault_dir)

    store_path = Path.join(System.tmp_dir!(), "kyber_condenser_store_#{suffix}.jsonl")
    File.rm(store_path)

    core_name = :"CondenserTestCore_#{suffix}"
    knowledge_name = :"#{core_name}.Knowledge"
    condenser_name = :"#{core_name}.Condenser"

    {:ok, knowledge} =
      Knowledge.start_link(
        name: knowledge_name,
        vault_path: vault_dir,
        poll_interval: 0
      )

    {:ok, core} =
      Core.start_link(
        name: core_name,
        store_path: store_path,
        plugins: []
      )

    {:ok, condenser} =
      Condenser.start_link(
        name: condenser_name,
        core: core_name,
        knowledge: knowledge_name
      )

    # Subscribe the test process to the isolated Core's Delta.Store so we
    # can assert_receive specific delta kinds without polling state.
    test_pid = self()
    store_name = :"#{core_name}.Store"

    Kyber.Delta.Store.subscribe(store_name, fn delta ->
      send(test_pid, {:store_delta, delta})
    end)

    on_exit(fn ->
      try do
        if Process.alive?(condenser), do: GenServer.stop(condenser, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(core), do: Supervisor.stop(core, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(knowledge), do: GenServer.stop(knowledge, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(vault_dir)
      File.rm(store_path)
    end)

    %{
      core_name: core_name,
      knowledge_name: knowledge_name,
      condenser_name: condenser_name,
      vault_dir: vault_dir
    }
  end

  test "llm.response delta triggers a vault write and emits memory.condensed", ctx do
    response = Delta.new("llm.response", %{
      "text" => "The Reducer must remain pure.",
      "model" => "claude-test",
      "conversation_id" => "conv-1"
    })

    Core.emit(ctx.core_name, response)

    # The Condenser writes the file synchronously *before* emitting
    # memory.condensed, so receiving this delta proves the file is on disk.
    assert_receive {:store_delta, %Delta{kind: "memory.condensed"} = condensed}, 5_000

    assert condensed.parent_id == response.id
    assert condensed.payload["source_delta_id"] == response.id
    rel_path = condensed.payload["path"]
    assert is_binary(rel_path)

    abs_path = Path.join(ctx.vault_dir, rel_path)
    assert File.exists?(abs_path), "expected condensed memory file at #{abs_path}"

    body = File.read!(abs_path)
    assert body =~ "The Reducer must remain pure."
    assert body =~ response.id
  end

  test "non-llm.response deltas do not trigger a memory.condensed", ctx do
    other = Delta.new("message.received", %{"text" => "hello"})
    Core.emit(ctx.core_name, other)

    # We will receive the message.received echo, but never a memory.condensed.
    refute_receive {:store_delta, %Delta{kind: "memory.condensed"}}, 200

    # And nothing should have been written under the condensed/ subdir.
    refute File.exists?(Path.join(ctx.vault_dir, "condensed"))
  end
end
