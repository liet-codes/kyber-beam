defmodule Kyber.Web.KnowledgeController do
  @moduledoc """
  Phoenix controller for Knowledge graph queries.

  GET /api/knowledge/notes         → list notes (optional ?type=memory&tags=elixir)
  GET /api/knowledge/notes/*path   → get a specific note
  """
  use Phoenix.Controller, formats: [:json]

  def index(conn, params) do
    knowledge = Process.whereis(Kyber.Knowledge) || Kyber.Knowledge

    filters =
      []
      |> then(fn f ->
        if t = params["type"],
          do: Keyword.put(f, :type, String.to_existing_atom(t)),
          else: f
      end)
      |> then(fn f ->
        if tags = params["tags"],
          do: Keyword.put(f, :tags, String.split(tags, ",")),
          else: f
      end)

    notes = Kyber.Knowledge.query_notes(knowledge, filters)

    json(conn, %{
      ok: true,
      count: length(notes),
      notes: Enum.map(notes, &note_to_json/1)
    })
  rescue
    _ -> json(conn, %{ok: true, count: 0, notes: []})
  end

  def show(conn, %{"path" => path_parts}) do
    path = Enum.join(path_parts, "/")
    knowledge = Process.whereis(Kyber.Knowledge) || Kyber.Knowledge

    case Kyber.Knowledge.get_note(knowledge, path) do
      {:ok, note} ->
        json(conn, %{ok: true, note: note_to_json(note)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "note not found"})
    end
  rescue
    _ ->
      conn
      |> put_status(503)
      |> json(%{ok: false, error: "knowledge service unavailable"})
  end

  defp note_to_json(note) do
    %{
      path: note.path,
      frontmatter: note.frontmatter,
      body: note.body,
      wikilinks: note.wikilinks
    }
  end
end
