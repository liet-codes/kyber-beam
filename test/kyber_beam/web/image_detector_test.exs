defmodule Kyber.Web.ImageDetectorTest do
  use ExUnit.Case, async: true

  alias Kyber.Web.ImageDetector

  # A minimal valid-ish PNG base64 prefix (>1000 chars)
  @fake_png_b64 "iVBOR" <> String.duplicate("AAAA", 300)
  @fake_jpeg_b64 "/9j/" <> String.duplicate("BBBB", 300)
  @short_b64 "iVBORshort"

  describe "extract_images/1" do
    test "returns empty for empty payload" do
      assert ImageDetector.extract_images(%{}) == []
    end

    test "returns empty for non-map" do
      assert ImageDetector.extract_images(nil) == []
      assert ImageDetector.extract_images("string") == []
    end

    test "detects explicit images list from tool_loop" do
      payload = %{
        "name" => "computer_use",
        "status" => "ok",
        "images" => [
          %{
            "label" => "Screenshot",
            "media_type" => "image/png",
            "base64" => @fake_png_b64
          }
        ]
      }

      result = ImageDetector.extract_images(payload)
      assert length(result) == 1
      [{label, mt, data}] = result
      assert label == "Screenshot"
      assert mt == "image/png"
      assert data == @fake_png_b64
    end

    test "detects Anthropic content block images" do
      payload = %{
        "content" => [
          %{
            "type" => "image",
            "source" => %{
              "type" => "base64",
              "media_type" => "image/png",
              "data" => @fake_png_b64
            }
          },
          %{
            "type" => "text",
            "text" => "Here is the screenshot"
          }
        ]
      }

      result = ImageDetector.extract_images(payload)
      assert length(result) == 1
      [{label, mt, _data}] = result
      assert mt == "image/png"
      assert label == "Image (PNG)"
    end

    test "detects named field 'screenshot'" do
      payload = %{"screenshot" => @fake_png_b64, "other" => "stuff"}

      result = ImageDetector.extract_images(payload)
      assert length(result) == 1
      [{label, mt, _}] = result
      assert label == "Screenshot"
      assert mt == "image/png"
    end

    test "detects named field 'image' with JPEG data" do
      payload = %{"image" => @fake_jpeg_b64}

      result = ImageDetector.extract_images(payload)
      assert length(result) == 1
      [{label, mt, _}] = result
      assert label == "Image"
      assert mt == "image/jpeg"
    end

    test "detects base64 in arbitrary nested fields" do
      payload = %{
        "result" => %{
          "rendered_output" => @fake_png_b64
        }
      }

      result = ImageDetector.extract_images(payload)
      assert length(result) == 1
      [{label, _mt, _}] = result
      assert label == "Rendered Output"
    end

    test "ignores short base64 strings" do
      payload = %{"screenshot" => @short_b64}
      assert ImageDetector.extract_images(payload) == []
    end

    test "ignores non-image base64 strings" do
      payload = %{"data" => String.duplicate("ZZZZ", 500)}
      assert ImageDetector.extract_images(payload) == []
    end

    test "handles multiple images" do
      payload = %{
        "images" => [
          %{"label" => "Screenshot", "media_type" => "image/png", "base64" => @fake_png_b64},
          %{"label" => "Camera", "media_type" => "image/jpeg", "base64" => @fake_jpeg_b64}
        ]
      }

      result = ImageDetector.extract_images(payload)
      assert length(result) == 2
    end

    test "deduplicates images found by multiple strategies" do
      # If same data appears in both "images" list and "screenshot" field
      payload = %{
        "images" => [
          %{"label" => "Screenshot", "media_type" => "image/png", "base64" => @fake_png_b64}
        ],
        "screenshot" => @fake_png_b64
      }

      result = ImageDetector.extract_images(payload)
      # Should deduplicate since it's the same data
      assert length(result) == 1
    end

    test "non-image payloads return empty" do
      payload = %{
        "name" => "exec",
        "status" => "ok",
        "output" => "Hello world, this is some text output from a tool"
      }

      assert ImageDetector.extract_images(payload) == []
    end
  end

  describe "has_images?/1" do
    test "returns true when images present" do
      payload = %{
        "images" => [
          %{"label" => "Screenshot", "media_type" => "image/png", "base64" => @fake_png_b64}
        ]
      }

      assert ImageDetector.has_images?(payload)
    end

    test "returns false when no images" do
      refute ImageDetector.has_images?(%{"text" => "hello"})
    end
  end

  describe "guess_media_type_public/1" do
    test "detects PNG" do
      assert ImageDetector.guess_media_type_public("iVBORsomething") == "image/png"
    end

    test "detects JPEG" do
      assert ImageDetector.guess_media_type_public("/9j/something") == "image/jpeg"
    end

    test "detects GIF" do
      assert ImageDetector.guess_media_type_public("R0lGODsomething") == "image/gif"
    end

    test "detects WebP" do
      assert ImageDetector.guess_media_type_public("UklGRsomething") == "image/webp"
    end

    test "returns nil for unknown" do
      assert ImageDetector.guess_media_type_public("randomdata") == nil
    end
  end
end
