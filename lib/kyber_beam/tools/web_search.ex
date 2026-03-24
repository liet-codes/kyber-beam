defmodule Kyber.Tools.WebSearch do
  @moduledoc """
  Web search tool supporting multiple providers (Brave Search, Google Custom Search).

  Falls back gracefully if no API key is configured, returning an empty result
  with a note that search requires an API key.

  ## Configuration

      config :kyber_beam, Kyber.Tools.WebSearch,
        provider: :brave,
        api_key: System.get_env("BRAVE_SEARCH_API_KEY", ""),
        max_results: 5

  ## Result format

  Returns `{:ok, results}` where results is a list of maps:

      [%{title: "...", url: "...", snippet: "...", date: "..."}]
  """

  require Logger

  @default_max_results 5

  @typedoc "A single search result"
  @type result :: %{
          title: String.t(),
          url: String.t(),
          snippet: String.t(),
          date: String.t() | nil
        }

  @doc """
  Search the web for the given query.

  ## Options

    * `:max_results` — maximum number of results to return (default: 5)
    * `:provider` — override the configured provider (`:brave`, `:google`, `:fallback`)
    * `:api_key` — override the configured API key

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, String.t()}
  def search(query, opts \\ []) do
    config = Application.get_env(:kyber_beam, __MODULE__, [])
    provider = Keyword.get(opts, :provider, Keyword.get(config, :provider, :brave))
    api_key = Keyword.get(opts, :api_key, Keyword.get(config, :api_key, ""))
    max_results = Keyword.get(opts, :max_results, Keyword.get(config, :max_results, @default_max_results))

    if api_key == "" or api_key == nil do
      Logger.info("[Kyber.Tools.WebSearch] no API key configured, returning fallback")
      {:ok, fallback_result(query)}
    else
      case provider do
        :brave -> search_brave(query, api_key, max_results)
        :google -> search_google(query, api_key, max_results)
        _ -> {:ok, fallback_result(query)}
      end
    end
  end

  # ── Brave Search ──────────────────────────────────────────────────────────

  defp search_brave(query, api_key, max_results) do
    url = "https://api.search.brave.com/res/v1/web/search"

    headers = [
      {"Accept", "application/json"},
      {"Accept-Encoding", "gzip"},
      {"X-Subscription-Token", api_key}
    ]

    params = [q: query, count: max_results]

    Logger.info("[Kyber.Tools.WebSearch] Brave search: #{query}")

    case Req.get(url,
           headers: headers,
           params: params,
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_brave_results(body, max_results)
        {:ok, results}

      {:ok, %{status: 429}} ->
        Logger.warning("[Kyber.Tools.WebSearch] Brave rate limited")
        {:error, "Search rate limited — try again later"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Kyber.Tools.WebSearch] Brave HTTP #{status}: #{inspect(body)}")
        {:error, "Search API returned HTTP #{status}"}

      {:error, reason} ->
        Logger.error("[Kyber.Tools.WebSearch] Brave request failed: #{inspect(reason)}")
        {:error, "Search request failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[Kyber.Tools.WebSearch] Brave search error: #{inspect(e)}")
      {:error, "Search error: #{inspect(e)}"}
  end

  defp parse_brave_results(body, max_results) when is_map(body) do
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

  defp parse_brave_results(body, max_results) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_brave_results(decoded, max_results)
      _ -> []
    end
  end

  defp parse_brave_results(_, _), do: []

  # ── Google Custom Search ──────────────────────────────────────────────────

  defp search_google(query, api_key, max_results) do
    config = Application.get_env(:kyber_beam, __MODULE__, [])
    cx = Keyword.get(config, :google_cx, "")

    if cx == "" do
      Logger.warning("[Kyber.Tools.WebSearch] Google CX not configured, falling back")
      {:ok, fallback_result(query)}
    else
      url = "https://www.googleapis.com/customsearch/v1"

      params = [key: api_key, cx: cx, q: query, num: min(max_results, 10)]

      Logger.info("[Kyber.Tools.WebSearch] Google search: #{query}")

      case Req.get(url,
             params: params,
             connect_options: [timeout: 5_000],
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          results = parse_google_results(body, max_results)
          {:ok, results}

        {:ok, %{status: status}} ->
          {:error, "Google Search API returned HTTP #{status}"}

        {:error, reason} ->
          {:error, "Google search failed: #{inspect(reason)}"}
      end
    end
  rescue
    e -> {:error, "Google search error: #{inspect(e)}"}
  end

  defp parse_google_results(body, max_results) when is_map(body) do
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

  defp parse_google_results(body, max_results) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_google_results(decoded, max_results)
      _ -> []
    end
  end

  defp parse_google_results(_, _), do: []

  # ── Fallback ──────────────────────────────────────────────────────────────

  defp fallback_result(query) do
    [
      %{
        title: "Web search not available",
        url: "",
        snippet:
          "No search API key configured. Set BRAVE_SEARCH_API_KEY or configure " <>
            ":kyber_beam, Kyber.Tools.WebSearch to enable web search. " <>
            "Query was: #{query}",
        date: nil
      }
    ]
  end
end
