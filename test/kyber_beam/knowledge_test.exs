defmodule Kyber.KnowledgeTest do
  use ExUnit.Case, async: true

  alias Kyber.Knowledge

  # Use a temp vault dir per test
  setup do
    vault_dir = Path.join(System.tmp_dir!(), "kyber_vault_#{:rand.uniform(999_999)}")
    File.mkdir_p!(vault_dir)

    {:ok, pid} =
      Knowledge.start_link(
        name: nil,
        vault_path: vault_dir,
        poll_interval: 0  # disable polling in tests
      )

    on_exit(fn ->
      File.rm_rf!(vault_dir)
    end)

    %{pid: pid, vault_dir: vault_dir}
  end

  # ── Frontmatter parsing ───────────────────────────────────────────────────

  describe "parse_frontmatter/1" do
    test "parses YAML frontmatter between --- delimiters" do
      content = """
      ---
      title: Test Note
      type: memory
      tags: [elixir, phoenix]
      ---

      This is the body.
      """

      {fm, body} = Knowledge.parse_frontmatter(content)
      assert fm["title"] == "Test Note"
      assert fm["type"] == "memory"
      assert fm["tags"] == ["elixir", "phoenix"]
      assert String.contains?(body, "This is the body.")
    end

    test "returns empty map and full content when no frontmatter" do
      content = "# Just a note\n\nNo frontmatter here."
      {fm, body} = Knowledge.parse_frontmatter(content)
      assert fm == %{}
      assert String.contains?(body, "No frontmatter here")
    end

    test "handles empty frontmatter" do
      content = "---\n---\n\nBody only."
      {fm, body} = Knowledge.parse_frontmatter(content)
      assert fm == %{}
      assert String.contains?(body, "Body only.")
    end
  end

  # ── Wikilink extraction ───────────────────────────────────────────────────

  describe "extract_wikilinks/1" do
    test "extracts simple wikilinks" do
      body = "See [[My Note]] and [[Another Note]] for more."
      links = Knowledge.extract_wikilinks(body)
      assert "My Note" in links
      assert "Another Note" in links
    end

    test "handles wikilinks with display text" do
      body = "See [[some/path|Display Text]] here."
      links = Knowledge.extract_wikilinks(body)
      assert "some/path" in links
      refute "Display Text" in links
    end

    test "returns empty list when no wikilinks" do
      body = "No links in this text."
      assert Knowledge.extract_wikilinks(body) == []
    end

    test "deduplicates repeated wikilinks" do
      body = "[[A]] and [[A]] and [[B]]"
      links = Knowledge.extract_wikilinks(body)
      assert length(links) == 2
    end
  end

  # ── Note CRUD ─────────────────────────────────────────────────────────────

  describe "put_note/get_note" do
    test "writes and reads a note", %{pid: pid} do
      frontmatter = %{"title" => "Hello", "type" => "concepts"}
      body = "This is my concept note."

      assert :ok = Knowledge.put_note(pid, "concepts/hello.md", frontmatter, body)
      assert {:ok, note} = Knowledge.get_note(pid, "concepts/hello.md")

      assert note.path == "concepts/hello.md"
      assert note.frontmatter["title"] == "Hello"
      assert note.body == body
    end

    test "returns error for missing note", %{pid: pid} do
      assert {:error, :not_found} = Knowledge.get_note(pid, "nonexistent.md")
    end

    test "normalizes path (adds .md extension)", %{pid: pid} do
      :ok = Knowledge.put_note(pid, "my-note", %{"title" => "X"}, "content")
      assert {:ok, _note} = Knowledge.get_note(pid, "my-note")
    end

    test "creates parent directories", %{pid: pid} do
      :ok = Knowledge.put_note(pid, "deep/nested/note.md", %{}, "hello")
      assert {:ok, note} = Knowledge.get_note(pid, "deep/nested/note.md")
      assert note.body == "hello"
    end
  end

  describe "delete_note/2" do
    test "deletes an existing note", %{pid: pid} do
      :ok = Knowledge.put_note(pid, "to-delete.md", %{}, "bye")
      assert :ok = Knowledge.delete_note(pid, "to-delete.md")
      assert {:error, :not_found} = Knowledge.get_note(pid, "to-delete.md")
    end

    test "returns error for missing note", %{pid: pid} do
      assert {:error, :not_found} = Knowledge.delete_note(pid, "ghost.md")
    end
  end

  # ── Querying ──────────────────────────────────────────────────────────────

  describe "query_notes/2" do
    setup %{pid: pid} do
      notes = [
        {"identity/soul.md", %{"type" => "identity", "tags" => ["self"]}, "Soul note"},
        {"memory/2025-01-01.md", %{"type" => "memory", "date" => "2025-01-01", "tags" => []}, "Day 1"},
        {"memory/2025-06-15.md", %{"type" => "memory", "date" => "2025-06-15", "tags" => ["reflection"]}, "June"},
        {"concepts/elixir.md", %{"type" => "concepts", "tags" => ["elixir", "beam"]}, "Elixir"},
        {"concepts/phoenix.md", %{"type" => "concepts", "tags" => ["elixir", "web"]}, "Phoenix"}
      ]

      Enum.each(notes, fn {path, fm, body} ->
        Knowledge.put_note(pid, path, fm, body)
      end)

      :ok
    end

    test "filter by type", %{pid: pid} do
      results = Knowledge.query_notes(pid, type: :memory)
      assert length(results) == 2
      assert Enum.all?(results, fn n -> n.frontmatter["type"] == "memory" end)
    end

    test "filter by single tag", %{pid: pid} do
      results = Knowledge.query_notes(pid, tags: ["elixir"])
      assert length(results) == 2
    end

    test "filter by multiple tags (AND)", %{pid: pid} do
      results = Knowledge.query_notes(pid, tags: ["elixir", "web"])
      assert length(results) == 1
      assert hd(results).frontmatter["tags"] == ["elixir", "web"]
    end

    test "filter by since date", %{pid: pid} do
      results = Knowledge.query_notes(pid, since: ~D[2025-06-01])
      assert length(results) == 1
      assert hd(results).frontmatter["date"] == "2025-06-15"
    end

    test "filter by until date", %{pid: pid} do
      results = Knowledge.query_notes(pid, until: ~D[2025-01-31])
      assert length(results) == 1
      assert hd(results).frontmatter["date"] == "2025-01-01"
    end

    test "no filters returns all notes", %{pid: pid} do
      results = Knowledge.query_notes(pid)
      assert length(results) == 5
    end
  end

  # ── list_notes ────────────────────────────────────────────────────────────

  describe "list_notes/2" do
    test "lists notes of a given type", %{pid: pid} do
      Knowledge.put_note(pid, "p1.md", %{"type" => "projects"}, "P1")
      Knowledge.put_note(pid, "p2.md", %{"type" => "projects"}, "P2")
      Knowledge.put_note(pid, "c1.md", %{"type" => "concepts"}, "C1")

      projects = Knowledge.list_notes(pid, :projects)
      assert length(projects) == 2
      assert Enum.all?(projects, fn n -> n.frontmatter["type"] == "projects" end)
    end

    test "returns empty list when no notes of that type", %{pid: pid} do
      assert Knowledge.list_notes(pid, :decisions) == []
    end
  end

  # ── Backlinks ─────────────────────────────────────────────────────────────

  describe "get_backlinks/2" do
    test "finds notes that link to a given note", %{pid: pid} do
      Knowledge.put_note(pid, "a.md", %{}, "See [[b]] for details.")
      Knowledge.put_note(pid, "c.md", %{}, "Also [[b]] is great.")
      Knowledge.put_note(pid, "b.md", %{}, "I am b.")

      backlinks = Knowledge.get_backlinks(pid, "b.md")
      paths = Enum.map(backlinks, & &1.path)
      assert "a.md" in paths
      assert "c.md" in paths
      refute "b.md" in paths
    end

    test "returns empty list when no backlinks", %{pid: pid} do
      Knowledge.put_note(pid, "lonely.md", %{}, "No links here.")
      assert Knowledge.get_backlinks(pid, "lonely.md") == []
    end
  end

  # ── Tiered context ────────────────────────────────────────────────────────

  describe "get_tiered/3" do
    setup %{pid: pid} do
      Knowledge.put_note(
        pid,
        "test-note.md",
        %{"title" => "My Note", "type" => "concepts", "tags" => ["test"]},
        "First paragraph here.\n\nSecond paragraph below.\n\nMore content."
      )

      :ok
    end

    test "L0 returns abstract (title, type, tags)", %{pid: pid} do
      assert {:ok, l0} = Knowledge.get_tiered(pid, "test-note.md", :l0)
      assert l0.title == "My Note"
      assert l0.type == "concepts"
      assert l0.tags == ["test"]
      refute Map.has_key?(l0, :body)
    end

    test "L1 returns frontmatter + first paragraph", %{pid: pid} do
      assert {:ok, l1} = Knowledge.get_tiered(pid, "test-note.md", :l1)
      assert l1.frontmatter["title"] == "My Note"
      assert l1.first_paragraph == "First paragraph here."
      refute Map.has_key?(l1, :body)
    end

    test "L2 returns full note", %{pid: pid} do
      assert {:ok, l2} = Knowledge.get_tiered(pid, "test-note.md", :l2)
      assert l2.body =~ "Second paragraph"
      assert l2.frontmatter["title"] == "My Note"
    end

    test "returns error for missing note", %{pid: pid} do
      assert {:error, :not_found} = Knowledge.get_tiered(pid, "missing.md", :l0)
    end
  end

  # ── Serialize/deserialize ─────────────────────────────────────────────────

  describe "note round-trip" do
    test "serialized note can be re-parsed", %{pid: pid, vault_dir: vault_dir} do
      fm = %{"title" => "Round trip", "type" => "tools", "tags" => ["test"]}
      body = "Testing persistence."

      :ok = Knowledge.put_note(pid, "roundtrip.md", fm, body)

      # Read the raw file and parse it
      raw = File.read!(Path.join(vault_dir, "roundtrip.md"))
      {parsed_fm, parsed_body} = Knowledge.parse_frontmatter(raw)

      assert parsed_fm["title"] == "Round trip"
      assert parsed_fm["type"] == "tools"
      assert String.trim(parsed_body) == body
    end
  end

  # ── vault_path ────────────────────────────────────────────────────────────

  describe "vault_path/1" do
    test "returns the configured vault path", %{pid: pid, vault_dir: vault_dir} do
      assert Knowledge.vault_path(pid) == vault_dir
    end
  end

  # ── Async vault reload ────────────────────────────────────────────────────

  describe "async vault reload" do
    test "GenServer continues serving reads while reload runs", %{pid: pid} do
      # Put a note so there's data to serve
      :ok = Knowledge.put_note(pid, "preload.md", %{"type" => "concepts"}, "Preloaded content")

      # Trigger a poll — this spawns a background Task, not a blocking call
      send(pid, :poll_vault)

      # The GenServer should respond to reads immediately (not blocked)
      assert {:ok, note} = Knowledge.get_note(pid, "preload.md")
      assert note.body == "Preloaded content"
    end

    test "external file changes are picked up after async reload", %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.subscribe(pid)

      # Write a file directly to disk (bypassing GenServer)
      external_path = Path.join(vault_dir, "external.md")
      File.write!(external_path, "---\ntitle: External\n---\n\nExternal content.")

      # Trigger a poll to pick up the change
      send(pid, :poll_vault)

      # Wait for the reload task to notify subscribers (replaces Process.sleep)
      assert_receive {:vault_changed, _}, 500

      # Note should now be in state
      assert {:ok, note} = Knowledge.get_note(pid, "external.md")
      assert note.frontmatter["title"] == "External"
    end

    test "reload_complete message atomically updates state", %{pid: pid} do
      :ok = Knowledge.put_note(pid, "atom-test.md", %{}, "Original")

      # Simulate a completed reload (as if the background task finished)
      new_note = %{
        path: "atom-test.md",
        frontmatter: %{"updated" => "true"},
        body: "Updated by reload",
        wikilinks: []
      }
      send(pid, {:reload_complete, {%{"atom-test.md" => new_note}, %{}, %{}, []}})

      # Issue a sync call to ensure the GenServer has processed the message above
      Knowledge.note_count(pid)

      assert {:ok, note} = Knowledge.get_note(pid, "atom-test.md")
      assert note.body == "Updated by reload"
    end

    test "deleted files are removed from state after reload", %{pid: pid, vault_dir: vault_dir} do
      # Write then delete a file externally
      :ok = Knowledge.put_note(pid, "doomed.md", %{}, "Soon gone")
      assert {:ok, _} = Knowledge.get_note(pid, "doomed.md")

      :ok = Knowledge.subscribe(pid)

      # Delete from disk directly
      File.rm!(Path.join(vault_dir, "doomed.md"))

      # Trigger async reload and wait for notification (replaces Process.sleep)
      send(pid, :poll_vault)
      assert_receive {:vault_changed, _}, 500

      assert {:error, :not_found} = Knowledge.get_note(pid, "doomed.md")
    end
  end

  # ── Subscription (vault_changed notifications) ────────────────────────────

  describe "subscribe/unsubscribe" do
    test "subscribe/1 registers and subscriber receives vault_changed on file change",
         %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.subscribe(pid)

      # Write a new file directly to disk (bypassing GenServer)
      ext_path = Path.join(vault_dir, "subscribed.md")
      File.write!(ext_path, "---\ntitle: Sub Test\n---\n\nContent.")

      # Trigger an async poll
      send(pid, :poll_vault)

      # The subscriber (this test process) should receive the message
      assert_receive {:vault_changed, paths}, 1_000
      assert "subscribed.md" in paths
    end

    test "unsubscribe/1 stops notifications", %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.subscribe(pid)
      :ok = Knowledge.unsubscribe(pid)

      ext_path = Path.join(vault_dir, "after-unsub.md")
      File.write!(ext_path, "content.")

      send(pid, :poll_vault)

      # Extend the refute window to cover full async reload; no sleep needed
      refute_receive {:vault_changed, _}, 500
    end

    test "deleted paths are included in vault_changed", %{pid: pid, vault_dir: vault_dir} do
      # First add a note so it's tracked
      :ok = Knowledge.put_note(pid, "to-delete-sub.md", %{"title" => "Doomed"}, "bye")

      :ok = Knowledge.subscribe(pid)

      # Delete from disk
      File.rm!(Path.join(vault_dir, "to-delete-sub.md"))

      send(pid, :poll_vault)

      assert_receive {:vault_changed, paths}, 1_000
      assert "to-delete-sub.md" in paths
    end

    test "no vault_changed sent when nothing changes", %{pid: pid} do
      :ok = Knowledge.subscribe(pid)

      # Trigger poll with no changes on disk
      send(pid, :poll_vault)
      Process.sleep(300)

      refute_receive {:vault_changed, _}, 100
    end

    test "duplicate subscribe is idempotent", %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.subscribe(pid)
      :ok = Knowledge.subscribe(pid)

      ext_path = Path.join(vault_dir, "dup-sub.md")
      File.write!(ext_path, "dup.")

      send(pid, :poll_vault)

      # Should receive exactly one message, not two
      assert_receive {:vault_changed, _paths}, 1_000
      refute_receive {:vault_changed, _}, 100
    end
  end

  # ── mtime-based polling ───────────────────────────────────────────────────

  describe "mtime-based incremental polling" do
    test "unchanged files are not re-read on poll", %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.put_note(pid, "stable.md", %{"type" => "tools"}, "Stable content")

      # Track note count before and after a poll
      count_before = Knowledge.note_count(pid)

      # Write a new file directly to disk
      new_file = Path.join(vault_dir, "new-from-disk.md")
      File.write!(new_file, "---\ntitle: New\n---\n\nNew file.")

      # Trigger incremental reload — only new-from-disk.md has a new mtime
      send(pid, :poll_vault)
      Process.sleep(200)

      count_after = Knowledge.note_count(pid)

      # We should have one more note now
      assert count_after == count_before + 1
      assert {:ok, _} = Knowledge.get_note(pid, "new-from-disk.md")
      # The stable note is still there
      assert {:ok, stable} = Knowledge.get_note(pid, "stable.md")
      assert stable.body == "Stable content"
    end

    test "modified file is re-read after mtime changes", %{pid: pid, vault_dir: vault_dir} do
      :ok = Knowledge.put_note(pid, "mtime-test.md", %{"title" => "V1"}, "Version 1")
      assert {:ok, v1} = Knowledge.get_note(pid, "mtime-test.md")
      assert v1.frontmatter["title"] == "V1"

      # Wait a moment so mtime changes (filesystem has ~1s resolution on HFS+)
      Process.sleep(1100)

      # Overwrite the file directly with new content
      abs_path = Path.join(vault_dir, "mtime-test.md")
      File.write!(abs_path, "---\ntitle: V2\n---\n\nVersion 2.")

      # Trigger reload
      send(pid, :poll_vault)
      Process.sleep(200)

      assert {:ok, v2} = Knowledge.get_note(pid, "mtime-test.md")
      assert v2.frontmatter["title"] == "V2"
    end
  end
end
