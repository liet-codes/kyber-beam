defmodule Kyber.Tools.PromptAnnotatorTest do
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta}
  alias Kyber.Tools.PromptAnnotator

  defp unique_name, do: :"PromptAnnotatorTest_#{System.unique_integer([:positive])}"

  defp start_core do
    path =
      System.tmp_dir!()
      |> Path.join("prompt_annotator_test_#{System.unique_integer([:positive])}.jsonl")

    name = unique_name()
    {:ok, pid} = Core.start_link(name: name, store_path: path, plugins: [])

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      File.rm(path)
    end)

    {:ok, pid, name}
  end

  describe "annotate/1 (pure)" do
    test "returns a prompt.annotated delta" do
      effect = %{
        type: :annotate_prompt,
        delta_id: "parent-id-abc",
        payload: %{"text" => "hello"},
        origin: {:channel, "discord", "ch_1", "u_1"}
      }

      delta = PromptAnnotator.annotate(effect)

      assert %Delta{kind: "prompt.annotated"} = delta
      assert delta.parent_id == "parent-id-abc"
      assert delta.origin == {:channel, "discord", "ch_1", "u_1"}
    end

    test "preserves the original payload fields and adds annotations" do
      effect = %{
        delta_id: "p1",
        payload: %{"text" => "hi", "channel_id" => "c1", "extra" => true},
        origin: {:human, "u1"}
      }

      delta = PromptAnnotator.annotate(effect)

      assert delta.payload["text"] == "hi"
      assert delta.payload["channel_id"] == "c1"
      assert delta.payload["extra"] == true
      assert is_map(delta.payload["annotations"])
      assert is_integer(delta.payload["annotated_at"])
    end

    test "defaults origin to {:system, _} when missing" do
      delta = PromptAnnotator.annotate(%{delta_id: "p1", payload: %{"text" => "hi"}})
      assert match?({:system, _}, delta.origin)
    end

    test "tolerates a nil payload" do
      delta = PromptAnnotator.annotate(%{delta_id: "p1", payload: nil})
      assert delta.kind == "prompt.annotated"
      assert is_map(delta.payload)
      assert is_map(delta.payload["annotations"])
    end

    test "is pure — same input produces equivalent output (modulo id/ts)" do
      effect = %{delta_id: "p1", payload: %{"text" => "hi"}, origin: {:human, "u1"}}

      d1 = PromptAnnotator.annotate(effect)
      d2 = PromptAnnotator.annotate(effect)

      assert d1.kind == d2.kind
      assert d1.parent_id == d2.parent_id
      assert d1.origin == d2.origin
      assert Map.delete(d1.payload, "annotated_at") == Map.delete(d2.payload, "annotated_at")
    end
  end

  describe "register/1 (handler integration)" do
    setup do
      {:ok, _pid, name} = start_core()
      :ok = PromptAnnotator.register(name)
      {:ok, core: name}
    end

    test "registered handler emits prompt.annotated when message.received fires", %{core: core} do
      test_pid = self()
      store = :"#{core}.Store"

      # Subscribe directly to the delta store and forward the annotated delta
      # to the test mailbox — assert_receive avoids any Process.sleep.
      Kyber.Delta.Store.subscribe(store, fn delta ->
        if delta.kind == "prompt.annotated", do: send(test_pid, {:annotated, delta})
      end)

      input = Delta.new("message.received", %{"text" => "ping"}, {:human, "u1"})
      :ok = Core.emit(core, input)

      assert_receive {:annotated, %Delta{kind: "prompt.annotated"} = annotated}, 2_000
      assert annotated.parent_id == input.id
      assert annotated.payload["text"] == "ping"
      assert is_map(annotated.payload["annotations"])
    end

    test "the full chain reaches :llm_call via prompt.annotated", %{core: core} do
      test_pid = self()

      Core.register_effect_handler(core, :llm_call, fn effect ->
        send(test_pid, {:llm_called, effect})
      end)

      input = Delta.new("message.received", %{"text" => "round-trip"}, {:human, "u1"})
      :ok = Core.emit(core, input)

      assert_receive {:llm_called, effect}, 2_000
      assert effect.type == :llm_call
      assert effect.payload["text"] == "round-trip"
      assert is_map(effect.payload["annotations"])
    end

    test "handler also works when triggered by emitting :annotate_prompt indirectly via cron heartbeat",
         %{core: core} do
      test_pid = self()
      store = :"#{core}.Store"

      Kyber.Delta.Store.subscribe(store, fn delta ->
        if delta.kind == "prompt.annotated", do: send(test_pid, {:annotated, delta})
      end)

      heartbeat = Delta.new("cron.fired", %{"job_name" => "heartbeat"}, {:cron, "heartbeat"})
      :ok = Core.emit(core, heartbeat)

      assert_receive {:annotated, %Delta{kind: "prompt.annotated"} = annotated}, 2_000
      assert annotated.parent_id == heartbeat.id
      assert annotated.payload["text"] =~ "heartbeat"
    end
  end
end
