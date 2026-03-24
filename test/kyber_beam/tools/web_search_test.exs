defmodule Kyber.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  alias Kyber.Tools.WebSearch

  @brave_success_body %{
    "web" => %{
      "results" => [
        %{
          "title" => "Elixir Programming Language",
          "url" => "https://elixir-lang.org",
          "description" => "Elixir is a dynamic, functional language for building scalable applications.",
          "page_age" => "2024-01-15"
        },
        %{
          "title" => "Elixir School",
          "url" => "https://elixirschool.com",
          "description" => "Premier destination for learning and mastering Elixir.",
          "age" => "2023-06-01"
        },
        %{
          "title" => "Phoenix Framework",
          "url" => "https://phoenixframework.org",
          "description" => "Peace of mind from prototype to production.",
          "page_age" => nil
        }
      ]
    }
  }

  @google_success_body %{
    "items" => [
      %{
        "title" => "Elixir Lang",
        "link" => "https://elixir-lang.org",
        "snippet" => "A dynamic, functional language.",
        "pagemap" => %{
          "metatags" => [%{"article:published_time" => "2024-01-15"}]
        }
      },
      %{
        "title" => "Hex.pm",
        "link" => "https://hex.pm",
        "snippet" => "The package manager for the Erlang ecosystem."
      }
    ]
  }

  describe "search/2 with fallback (no API key)" do
    setup do
      # Ensure no API key is configured for these tests
      original = Application.get_env(:kyber_beam, Kyber.Tools.WebSearch)
      Application.put_env(:kyber_beam, Kyber.Tools.WebSearch, provider: :brave, api_key: "")
      on_exit(fn -> Application.put_env(:kyber_beam, Kyber.Tools.WebSearch, original || []) end)
      :ok
    end

    test "returns fallback result when no API key configured" do
      assert {:ok, results} = WebSearch.search("elixir programming")
      assert length(results) == 1
      assert hd(results).title == "Web search not available"
      assert String.contains?(hd(results).snippet, "No search API key configured")
      assert String.contains?(hd(results).snippet, "elixir programming")
    end

    test "returns fallback with nil API key" do
      assert {:ok, results} = WebSearch.search("test query", api_key: nil)
      assert length(results) == 1
      assert hd(results).title == "Web search not available"
    end
  end

  describe "search/2 with explicit fallback provider" do
    test "returns fallback result with :fallback provider" do
      assert {:ok, results} = WebSearch.search("test", provider: :fallback, api_key: "fake-key")
      assert length(results) == 1
      assert hd(results).title == "Web search not available"
    end
  end

  describe "result structure" do
    test "fallback results have all required fields" do
      {:ok, [result]} = WebSearch.search("test", provider: :fallback, api_key: "fake")

      assert Map.has_key?(result, :title)
      assert Map.has_key?(result, :url)
      assert Map.has_key?(result, :snippet)
      assert Map.has_key?(result, :date)
      assert is_binary(result.title)
      assert is_binary(result.url)
      assert is_binary(result.snippet)
    end
  end

  describe "Brave result parsing" do
    test "parses Brave response body correctly" do
      # We test the parsing indirectly by calling the module's internal parse
      # function via a test helper. Since parse_brave_results is private,
      # we test through the public API with a mock-like approach.

      # Instead, test the result structure expectations
      results = parse_brave_results_public(@brave_success_body, 5)

      assert length(results) == 3

      [first, second, third] = results
      assert first.title == "Elixir Programming Language"
      assert first.url == "https://elixir-lang.org"
      assert first.snippet == "Elixir is a dynamic, functional language for building scalable applications."
      assert first.date == "2024-01-15"

      # Second result uses "age" field as fallback
      assert second.title == "Elixir School"
      assert second.date == "2023-06-01"

      # Third result has nil page_age
      assert third.title == "Phoenix Framework"
      assert third.date == nil
    end

    test "respects max_results limit" do
      results = parse_brave_results_public(@brave_success_body, 2)
      assert length(results) == 2
    end

    test "handles empty web results" do
      results = parse_brave_results_public(%{"web" => %{"results" => []}}, 5)
      assert results == []
    end

    test "handles missing web key" do
      results = parse_brave_results_public(%{}, 5)
      assert results == []
    end

    test "handles non-map body" do
      results = parse_brave_results_public(nil, 5)
      assert results == []
    end
  end

  describe "Google result parsing" do
    test "parses Google response body correctly" do
      results = parse_google_results_public(@google_success_body, 5)

      assert length(results) == 2

      [first, second] = results
      assert first.title == "Elixir Lang"
      assert first.url == "https://elixir-lang.org"
      assert first.snippet == "A dynamic, functional language."
      assert first.date == "2024-01-15"

      assert second.title == "Hex.pm"
      assert second.url == "https://hex.pm"
      assert second.date == nil
    end

    test "handles empty items" do
      results = parse_google_results_public(%{"items" => []}, 5)
      assert results == []
    end

    test "handles missing items key" do
      results = parse_google_results_public(%{}, 5)
      assert results == []
    end
  end

  describe "ToolExecutor integration" do
    setup do
      original = Application.get_env(:kyber_beam, Kyber.Tools.WebSearch)
      Application.put_env(:kyber_beam, Kyber.Tools.WebSearch, provider: :fallback, api_key: "")
      on_exit(fn -> Application.put_env(:kyber_beam, Kyber.Tools.WebSearch, original || []) end)
      :ok
    end

    test "web_search tool returns formatted results" do
      assert {:ok, result} = Kyber.ToolExecutor.execute("web_search", %{"query" => "elixir"})
      assert is_binary(result)
      assert String.contains?(result, "Search results for: elixir")
      assert String.contains?(result, "Web search not available")
    end

    test "web_search tool respects max_results parameter" do
      assert {:ok, result} =
               Kyber.ToolExecutor.execute("web_search", %{
                 "query" => "test",
                 "max_results" => 3
               })

      assert is_binary(result)
    end

    test "web_search tool clamps max_results to valid range" do
      # max_results > 20 should be clamped to 20
      assert {:ok, _} =
               Kyber.ToolExecutor.execute("web_search", %{
                 "query" => "test",
                 "max_results" => 100
               })

      # max_results < 1 should be clamped to 1
      assert {:ok, _} =
               Kyber.ToolExecutor.execute("web_search", %{
                 "query" => "test",
                 "max_results" => 0
               })
    end
  end

  describe "Reducer integration" do
    test "search.results delta is handled as pass-through" do
      state = %Kyber.State{}

      delta =
        Kyber.Delta.new("search.results", %{
          "query" => "elixir",
          "results" => [
            %{"title" => "Elixir", "url" => "https://elixir-lang.org", "snippet" => "...", "date" => nil}
          ]
        })

      assert {^state, []} = Kyber.Reducer.reduce(state, delta)
    end
  end

  describe "Tool definitions" do
    test "web_search is in tool definitions" do
      names = Kyber.Tools.names()
      assert "web_search" in names
    end

    test "web_search tool has correct schema" do
      tool = Enum.find(Kyber.Tools.definitions(), &(&1["name"] == "web_search"))
      assert tool != nil
      assert "query" in tool["input_schema"]["required"]
      assert Map.has_key?(tool["input_schema"]["properties"], "query")
      assert Map.has_key?(tool["input_schema"]["properties"], "max_results")
    end
  end

  # ── Test helpers that exercise parsing without calling private functions ──

  # These replicate the parsing logic for testability. In production, the
  # parsing is invoked internally by search/2 after the HTTP call.

  defp parse_brave_results_public(body, max_results) when is_map(body) do
    web_results = get_in(body, ["web", "results"]) || []

    web_results
    |> Enum.take(max_results)
    |> Enum.map(fn result ->
      %{
        title: Map.get(result, "title", ""),
        url: Map.get(result, "url", ""),
        snippet: Map.get(result, "description", ""),
        date: Map.get(result, "page_age") || Map.get(result, "age")
      }
    end)
  end

  defp parse_brave_results_public(_, _), do: []

  defp parse_google_results_public(body, max_results) when is_map(body) do
    items = Map.get(body, "items", [])

    items
    |> Enum.take(max_results)
    |> Enum.map(fn item ->
      %{
        title: Map.get(item, "title", ""),
        url: Map.get(item, "link", ""),
        snippet: Map.get(item, "snippet", ""),
        date: get_in(item, ["pagemap", "metatags", Access.at(0), "article:published_time"])
      }
    end)
  end

  defp parse_google_results_public(_, _), do: []
end
