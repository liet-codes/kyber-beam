defmodule Kyber.Tools.PromptAnnotatorTest do
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta, Knowledge}
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

  # ── Stage 1 of the Two-Stage RAG: lightweight L0 surfacing ──────────────────
  #
  # The annotator should consult an Obsidian-style vault, find concepts whose
  # titles are mentioned in the prompt text, and embed L0 views of them
  # (title / type / tags) into `payload["annotations"]["l0"]`. These tests
  # describe that contract; today's `build_annotations/1` is a stub returning
  # `%{}`, so they fail until the surfacing is implemented.
  describe "annotate/1 with L0 vault surfacing" do
    setup do
      vault_dir =
        System.tmp_dir!()
        |> Path.join("annotator_vault_#{System.unique_integer([:positive])}")

      File.mkdir_p!(vault_dir)

      {:ok, knowledge} =
        Knowledge.start_link(
          name: nil,
          vault_path: vault_dir,
          poll_interval: 0
        )

      on_exit(fn ->
        if Process.alive?(knowledge) do
          try do
            GenServer.stop(knowledge, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        File.rm_rf!(vault_dir)
      end)

      {:ok, knowledge: knowledge, vault_dir: vault_dir}
    end

    defp l0_title(entry), do: Map.get(entry, "title") || Map.get(entry, :title)
    defp l0_type(entry), do: Map.get(entry, "type") || Map.get(entry, :type)

    defp l0_entries(delta) do
      case get_in(delta.payload, ["annotations", "l0"]) do
        nil -> []
        list when is_list(list) -> list
      end
    end

    test "surfaces an L0 concept when the prompt mentions its title", %{knowledge: knowledge} do
      :ok =
        Knowledge.put_note(
          knowledge,
          "kyber.md",
          %{"title" => "Kyber", "type" => "concepts", "tags" => ["architecture", "elixir"]},
          "Kyber is the cognitive harness built on Elixir/OTP.\n"
        )

      effect = %{
        delta_id: "p-surface",
        payload: %{"text" => "tell me about Kyber"},
        origin: {:human, "u1"},
        knowledge: knowledge
      }

      delta = PromptAnnotator.annotate(effect)

      assert %Delta{kind: "prompt.annotated"} = delta
      assert delta.parent_id == "p-surface"

      l0 = l0_entries(delta)
      assert l0 != [], "expected at least one L0 entry surfaced for matching prompt, got []"

      match = Enum.find(l0, fn entry -> l0_title(entry) == "Kyber" end)

      assert match,
             "expected an L0 entry with title \"Kyber\", got: #{inspect(l0)}"

      assert l0_type(match) == "concepts"
    end

    test "matches the concept title case-insensitively", %{knowledge: knowledge} do
      :ok =
        Knowledge.put_note(
          knowledge,
          "kyber.md",
          %{"title" => "Kyber", "type" => "concepts"},
          "Body.\n"
        )

      effect = %{
        delta_id: "p-case",
        payload: %{"text" => "what is KYBER actually?"},
        origin: {:human, "u1"},
        knowledge: knowledge
      }

      delta = PromptAnnotator.annotate(effect)
      l0 = l0_entries(delta)

      assert Enum.any?(l0, fn entry -> l0_title(entry) == "Kyber" end),
             "case-insensitive title match failed; got: #{inspect(l0)}"
    end

    test "produces no L0 entries when the prompt has no matches", %{knowledge: knowledge} do
      :ok =
        Knowledge.put_note(
          knowledge,
          "kyber.md",
          %{"title" => "Kyber", "type" => "concepts"},
          "Body.\n"
        )

      effect = %{
        delta_id: "p-miss",
        payload: %{"text" => "what is the weather today"},
        origin: {:human, "u1"},
        knowledge: knowledge
      }

      delta = PromptAnnotator.annotate(effect)
      l0 = l0_entries(delta)

      refute Enum.any?(l0, fn entry -> l0_title(entry) == "Kyber" end),
             "should not surface unrelated concept; got: #{inspect(l0)}"
    end

    test "preserves the original payload alongside the annotations", %{knowledge: knowledge} do
      :ok =
        Knowledge.put_note(
          knowledge,
          "kyber.md",
          %{"title" => "Kyber", "type" => "concepts"},
          "Body.\n"
        )

      effect = %{
        delta_id: "p-preserve",
        payload: %{"text" => "Kyber stuff", "channel_id" => "c-1"},
        origin: {:human, "u1"},
        knowledge: knowledge
      }

      delta = PromptAnnotator.annotate(effect)

      assert delta.payload["text"] == "Kyber stuff"
      assert delta.payload["channel_id"] == "c-1"
      assert is_map(delta.payload["annotations"])
      assert is_integer(delta.payload["annotated_at"])
    end

    test "surfaces the matching concept and not the non-matching one", %{knowledge: knowledge} do
      :ok =
        Knowledge.put_note(
          knowledge,
          "kyber.md",
          %{"title" => "Kyber", "type" => "concepts"},
          "Kyber concept.\n"
        )

      :ok =
        Knowledge.put_note(
          knowledge,
          "rhizome.md",
          %{"title" => "Rhizome", "type" => "concepts"},
          "Rhizome concept.\n"
        )

      effect = %{
        delta_id: "p-discriminate",
        payload: %{"text" => "explain Kyber to me"},
        origin: {:human, "u1"},
        knowledge: knowledge
      }

      delta = PromptAnnotator.annotate(effect)
      titles = delta |> l0_entries() |> Enum.map(&l0_title/1)

      assert "Kyber" in titles, "expected Kyber to be surfaced; got: #{inspect(titles)}"
      refute "Rhizome" in titles, "Rhizome should not be surfaced; got: #{inspect(titles)}"
    end
  end
end
