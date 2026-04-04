defmodule Kyber.Tools.ComputerUse.Screenshot do
  @moduledoc """
  Captures macOS desktop screenshots using the built-in `screencapture` utility.

  Returns base64-encoded PNG data resized to a max width of 1280px
  (Anthropic's recommended resolution for computer use).

  Supports full-screen and region captures.
  """

  require Logger

  @tmp_path "/tmp/kyber_screenshot.png"
  @max_width 1280

  @type result :: %{
          base64: String.t(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          format: String.t()
        }

  @doc """
  Capture a screenshot of the entire screen or a specific region.

  ## Options

    * `:region` — `{x, y, w, h}` tuple for region capture (optional)
    * `:cmd_runner` — function for running shell commands, defaults to `System.cmd/3`.
      Signature: `(executable, args, opts) -> {output, exit_code}`

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec capture(keyword()) :: {:ok, result()} | {:error, String.t()}
  def capture(opts \\ []) do
    region = Keyword.get(opts, :region)
    cmd_runner = Keyword.get(opts, :cmd_runner, &System.cmd/3)
    tmp_path = Keyword.get(opts, :tmp_path, @tmp_path)

    with :ok <- take_screenshot(region, tmp_path, cmd_runner),
         :ok <- resize_image(tmp_path, cmd_runner),
         {:ok, dimensions} <- get_dimensions(tmp_path, cmd_runner),
         {:ok, data} <- File.read(tmp_path) do
      base64 = Base.encode64(data)

      {:ok,
       %{
         base64: base64,
         width: dimensions.width,
         height: dimensions.height,
         format: "png"
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  after
    # Clean up temp file
    File.rm(Keyword.get(opts, :tmp_path, @tmp_path))
  end

  @screencapture_cmd (if File.exists?("/usr/sbin/screencapture"), do: "/usr/sbin/screencapture", else: "screencapture")

  defp take_screenshot(nil, tmp_path, cmd_runner) do
    case cmd_runner.(@screencapture_cmd, ["-x", "-t", "png", tmp_path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "screencapture failed (exit #{code}): #{output}"}
    end
  end

  defp take_screenshot({x, y, w, h}, tmp_path, cmd_runner) do
    region_str = "#{x},#{y},#{w},#{h}"

    case cmd_runner.(@screencapture_cmd, ["-x", "-R", region_str, "-t", "png", tmp_path],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, "screencapture region failed (exit #{code}): #{output}"}
    end
  end

  defp resize_image(tmp_path, cmd_runner) do
    # Get current width first
    case get_dimensions(tmp_path, cmd_runner) do
      {:ok, %{width: w}} when w > @max_width ->
        case cmd_runner.("sips", ["--resampleWidth", "#{@max_width}", tmp_path],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, code} -> {:error, "sips resize failed (exit #{code}): #{output}"}
        end

      {:ok, _} ->
        # Already within max width
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_dimensions(tmp_path, cmd_runner) do
    case cmd_runner.("sips", ["-g", "pixelWidth", "-g", "pixelHeight", tmp_path],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        width =
          case Regex.run(~r/pixelWidth:\s*(\d+)/, output) do
            [_, w] -> String.to_integer(w)
            _ -> 0
          end

        height =
          case Regex.run(~r/pixelHeight:\s*(\d+)/, output) do
            [_, h] -> String.to_integer(h)
            _ -> 0
          end

        {:ok, %{width: width, height: height}}

      {output, code} ->
        {:error, "sips dimensions failed (exit #{code}): #{output}"}
    end
  end
end
