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
end
