defmodule Kyber.Web.ImageDetector do
  @moduledoc """
  Detects base64 image data in delta payloads.

  Recursively scans a delta's payload map for embedded images using multiple
  heuristics:

  - Explicit `"images"` list (as emitted by tool_loop.ex for :ok_image results)
  - Content blocks with `"type" => "image"` and `"source" => %{"type" => "base64", ...}`
  - Named fields (`screenshot`, `image`, `image_data`) containing long base64 strings
  - Any string starting with known base64 PNG/JPEG headers and longer than 1000 chars

  Returns a list of `{label, media_type, base64_data}` tuples.
  """

  @min_base64_length 1000

  @image_field_names ~w(screenshot image image_data)

  @doc """
  Extract images from a delta's payload.

  Returns a list of `{label, media_type, base64_data}` tuples.
  """
  @spec extract_images(map()) :: [{String.t(), String.t(), String.t()}]
  def extract_images(payload) when is_map(payload) do
    images =
      extract_explicit_images(payload) ++
        extract_content_block_images(payload) ++
        extract_named_field_images(payload) ++
        scan_for_base64(payload)

    images
    |> Enum.uniq_by(fn {_label, _type, data} -> :erlang.phash2(String.slice(data, 0, 200)) end)
  end

  def extract_images(_), do: []

  @doc """
  Returns true if the payload contains any detectable images.
  """
  @spec has_images?(map()) :: boolean()
  def has_images?(payload), do: extract_images(payload) != []

  # ── Extraction strategies ─────────────────────────────────────────────

  # Strategy 1: Explicit "images" list from tool_loop.ex
  defp extract_explicit_images(%{"images" => images}) when is_list(images) do
    Enum.flat_map(images, fn
      %{"label" => label, "media_type" => mt, "base64" => b64} when is_binary(b64) ->
        [{label, mt, b64}]

      _ ->
        []
    end)
  end

  defp extract_explicit_images(_), do: []

  # Strategy 2: Content blocks with type "image" (Anthropic API format)
  defp extract_content_block_images(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "image", "source" => %{"type" => "base64", "media_type" => mt, "data" => data}}
      when is_binary(data) ->
        [{infer_label_from_media_type(mt), mt, data}]

      _ ->
        []
    end)
  end

  defp extract_content_block_images(_), do: []

  # Strategy 3: Named fields containing long base64 strings
  defp extract_named_field_images(payload) when is_map(payload) do
    Enum.flat_map(@image_field_names, fn field ->
      case Map.get(payload, field) do
        val when is_binary(val) and byte_size(val) > @min_base64_length ->
          mt = guess_media_type(val)

          if mt do
            [{humanize_field(field), mt, val}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  # Strategy 4: Deep scan for any long base64 strings with image headers
  defp scan_for_base64(payload) when is_map(payload) do
    # Skip keys already handled by other strategies
    skip_keys = MapSet.new(["images", "content" | @image_field_names])

    payload
    |> Enum.flat_map(fn {key, value} ->
      if MapSet.member?(skip_keys, key) do
        []
      else
        scan_value(key, value)
      end
    end)
  end

  defp scan_value(key, value) when is_binary(value) and byte_size(value) > @min_base64_length do
    case guess_media_type(value) do
      nil -> []
      mt -> [{humanize_field(key), mt, value}]
    end
  end

  defp scan_value(_key, value) when is_map(value) do
    extract_images(value)
  end

  defp scan_value(_key, value) when is_list(value) do
    Enum.flat_map(value, fn
      item when is_map(item) -> extract_images(item)
      _ -> []
    end)
  end

  defp scan_value(_key, _value), do: []

  # ── Helpers ───────────────────────────────────────────────────────────

  @doc """
  Guess the media type from the first bytes of a base64 string.
  Returns nil if not recognized as an image.
  """
  @spec guess_media_type_public(binary()) :: String.t() | nil
  def guess_media_type_public(data), do: guess_media_type(data)

  defp guess_media_type(data) when is_binary(data) do
    cond do
      String.starts_with?(data, "iVBOR") -> "image/png"
      String.starts_with?(data, "/9j/") -> "image/jpeg"
      String.starts_with?(data, "R0lGOD") -> "image/gif"
      String.starts_with?(data, "UklGR") -> "image/webp"
      true -> nil
    end
  end

  defp infer_label_from_media_type("image/png"), do: "Image (PNG)"
  defp infer_label_from_media_type("image/jpeg"), do: "Image (JPEG)"
  defp infer_label_from_media_type("image/" <> fmt), do: "Image (#{String.upcase(fmt)})"
  defp infer_label_from_media_type(_), do: "Image"

  defp humanize_field("screenshot"), do: "Screenshot"
  defp humanize_field("image"), do: "Image"
  defp humanize_field("image_data"), do: "Image Data"

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
