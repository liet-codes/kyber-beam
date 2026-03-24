defmodule Kyber.Tools.WebFetch do
  @moduledoc """
  Readability-mode web content extraction.

  Fetches a URL and returns clean, readable text — like a browser's Reader View.
  Strips scripts, styles, navigation, and other non-content elements, preserves
  paragraph structure, and decodes HTML entities.

  ## Usage

      iex> Kyber.Tools.WebFetch.fetch("https://example.com/article")
      {:ok, %{title: "Article Title", content: "...", url: "https://...", word_count: 342}}

  ## Options

    * `:max_chars` — maximum characters in returned content (default: 10_000)
    * `:timeout_ms` — HTTP request timeout in milliseconds (default: 10_000)
  """

  require Logger

  @default_max_chars 10_000
  @default_timeout_ms 10_000

  @type result :: %{
          title: String.t() | nil,
          content: String.t(),
          url: String.t(),
          word_count: non_neg_integer()
        }

  @doc """
  Fetch a URL and extract readable text content.

  Returns `{:ok, result}` with title, content, url, and word_count,
  or `{:error, reason}` on failure.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def fetch(url, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    cond do
      not is_binary(url) or url == "" ->
        {:error, "invalid URL: must be a non-empty string"}

      not String.starts_with?(url, ["http://", "https://"]) ->
        {:error, "URL must start with http:// or https://"}

      not ssrf_safe?(url) ->
        {:error, "blocked: private/internal address"}

      true ->
        do_fetch(url, max_chars, timeout_ms)
    end
  end

  defp do_fetch(url, max_chars, timeout_ms) do
    Logger.info("[Kyber.Tools.WebFetch] fetching: #{url}")

    case Req.get(url,
           connect_options: [timeout: timeout_ms],
           receive_timeout: timeout_ms,
           decode_body: false,
           headers: [
             {"user-agent", "KyberBeam/0.2 (readability bot)"},
             {"accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8"}
           ]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        title = extract_title(body)
        content = extract_readable_text(body)

        truncated =
          if String.length(content) > max_chars do
            String.slice(content, 0, max_chars) <> "\n\n[content truncated at #{max_chars} characters]"
          else
            content
          end

        word_count = truncated |> String.split(~r/\s+/, trim: true) |> length()

        {:ok, %{title: title, content: truncated, url: url, word_count: word_count}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} fetching #{url}"}

      {:error, %{reason: :timeout}} ->
        {:error, "timeout fetching #{url}"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "web_fetch error: #{Exception.message(e)}"}
  end

  # ── HTML → Readable Text ────────────────────────────────────────────────

  @doc false
  def extract_readable_text(html) when is_binary(html) do
    html
    |> remove_non_content_tags()
    |> convert_block_elements_to_newlines()
    |> strip_remaining_tags()
    |> decode_entities()
    |> clean_whitespace()
    |> String.trim()
  end

  def extract_readable_text(other), do: inspect(other)

  @doc false
  def extract_title(html) when is_binary(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/si, html) do
      [_, title] ->
        title
        |> strip_remaining_tags()
        |> decode_entities()
        |> String.trim()
        |> case do
          "" -> nil
          t -> t
        end

      _ ->
        nil
    end
  end

  def extract_title(_), do: nil

  # Remove entire tag blocks that don't contain readable content
  defp remove_non_content_tags(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/si, "")
    |> String.replace(~r/<nav[^>]*>.*?<\/nav>/si, "")
    |> String.replace(~r/<footer[^>]*>.*?<\/footer>/si, "")
    |> String.replace(~r/<header[^>]*>.*?<\/header>/si, "")
    |> String.replace(~r/<aside[^>]*>.*?<\/aside>/si, "")
    |> String.replace(~r/<noscript[^>]*>.*?<\/noscript>/si, "")
    |> String.replace(~r/<!--.*?-->/s, "")
  end

  # Convert block-level elements to paragraph breaks
  defp convert_block_elements_to_newlines(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/(?:p|div|article|section|blockquote|h[1-6]|li|tr|dd|dt)>/i, "\n\n")
    |> String.replace(~r/<(?:p|div|article|section|blockquote|h[1-6]|li|tr|dd|dt)(?:\s[^>]*)?>/, "\n\n")
  end

  # Remove all remaining HTML tags
  defp strip_remaining_tags(html) do
    String.replace(html, ~r/<[^>]+>/, "")
  end

  # Decode common HTML entities
  @doc false
  def decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&mdash;", "—")
    |> String.replace("&ndash;", "–")
    |> String.replace("&hellip;", "…")
    |> String.replace("&copy;", "©")
    |> String.replace("&reg;", "®")
    |> String.replace("&trade;", "™")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(text) do
    # &#123; decimal entities
    text =
      Regex.replace(~r/&#(\d+);/, text, fn _, code_str ->
        case Integer.parse(code_str) do
          {code, _} when code > 0 and code < 0x110000 ->
            try do
              <<code::utf8>>
            rescue
              _ -> ""
            end

          _ ->
            ""
        end
      end)

    # &#x1F4A9; hex entities
    Regex.replace(~r/&#x([0-9a-fA-F]+);/, text, fn _, hex_str ->
      case Integer.parse(hex_str, 16) do
        {code, _} when code > 0 and code < 0x110000 ->
          try do
            <<code::utf8>>
          rescue
            _ -> ""
          end

        _ ->
          ""
      end
    end)
  end

  # Collapse excessive whitespace while preserving paragraph structure
  defp clean_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/ *\n */m, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  # ── SSRF Protection ──────────────────────────────────────────────────────

  defp ssrf_safe?(url) do
    uri = URI.parse(url)
    host = uri.host || ""

    cond do
      host == "" -> false
      host == "localhost" -> false
      String.starts_with?(host, "127.") -> false
      String.starts_with?(host, "10.") -> false
      String.starts_with?(host, "192.168.") -> false
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, host) -> false
      host == "0.0.0.0" -> false
      host == "::1" -> false
      host == "[::1]" -> false
      String.ends_with?(host, ".local") -> false
      String.ends_with?(host, ".internal") -> false
      true -> true
    end
  end
end
