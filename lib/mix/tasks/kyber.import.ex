defmodule Mix.Tasks.Kyber.Import.Openclaw do
  @shortdoc "Import an OpenClaw vault zip into ~/.kyber/vault"
  @moduledoc """
  Import identity and memory files from an OpenClaw vault archive.

  Extracts SOUL.md, MEMORY.md, USER.md, TOOLS.md, IDENTITY.md into
  `~/.kyber/vault/identity/` and memory/*.md files into `~/.kyber/vault/memory/`.

  ## Usage

      mix kyber.import.openclaw /path/to/openclaw-export.zip

  """

  use Mix.Task

  @vault_dir Path.expand("~/.kyber/vault")
  @identity_files ~w(SOUL.md MEMORY.md USER.md TOOLS.md IDENTITY.md)

  @impl Mix.Task
  def run([zip_path]) do
    zip_path = Path.expand(zip_path)

    unless File.exists?(zip_path) do
      Mix.raise("File not found: #{zip_path}")
    end

    identity_dir = Path.join(@vault_dir, "identity")
    memory_dir = Path.join(@vault_dir, "memory")
    File.mkdir_p!(identity_dir)
    File.mkdir_p!(memory_dir)

    tmp_dir = Path.join(System.tmp_dir!(), "kyber_import_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    try do
      Mix.shell().info("Extracting #{zip_path}...")

      case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(tmp_dir)}]) do
        {:ok, files} ->
          files = Enum.map(files, &to_string/1)
          import_identity_files(files, identity_dir)
          import_memory_files(files, memory_dir)
          Mix.shell().info("OpenClaw import complete → #{@vault_dir}")

        {:error, reason} ->
          Mix.raise("Failed to extract zip: #{inspect(reason)}")
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  def run(_) do
    Mix.raise("Usage: mix kyber.import.openclaw <zip_path>")
  end

  defp import_identity_files(files, identity_dir) do
    for name <- @identity_files do
      case Enum.find(files, &String.ends_with?(&1, "/#{name}")) do
        nil ->
          # Try exact match (file at root of zip)
          case Enum.find(files, &(Path.basename(&1) == name)) do
            nil -> Mix.shell().info("  #{name} not found in archive")
            path -> copy_file(path, Path.join(identity_dir, name), name)
          end

        path ->
          copy_file(path, Path.join(identity_dir, name), name)
      end
    end
  end

  defp import_memory_files(files, memory_dir) do
    memory_files =
      Enum.filter(files, fn f ->
        String.contains?(f, "/memory/") && String.ends_with?(f, ".md") && File.regular?(f)
      end)

    if memory_files == [] do
      Mix.shell().info("  No memory/*.md files found in archive")
    else
      for file <- memory_files do
        basename = Path.basename(file)
        copy_file(file, Path.join(memory_dir, basename), "memory/#{basename}")
      end
    end
  end

  defp copy_file(src, dest, label) do
    File.cp!(src, dest)
    Mix.shell().info("  Imported #{label}")
  end
end

defmodule Mix.Tasks.Kyber.Import.Kyber do
  @shortdoc "Import a Kyber vault zip into ~/.kyber/vault"
  @moduledoc """
  Import an existing Kyber vault archive directly into ~/.kyber/vault/.

  The zip contents are extracted directly into the vault directory.

  ## Usage

      mix kyber.import.kyber /path/to/kyber-vault.zip

  """

  use Mix.Task

  @vault_dir Path.expand("~/.kyber/vault")

  @impl Mix.Task
  def run([zip_path]) do
    zip_path = Path.expand(zip_path)

    unless File.exists?(zip_path) do
      Mix.raise("File not found: #{zip_path}")
    end

    File.mkdir_p!(@vault_dir)

    Mix.shell().info("Extracting #{zip_path} → #{@vault_dir}...")

    case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(@vault_dir)}]) do
      {:ok, files} ->
        Mix.shell().info("Imported #{length(files)} files → #{@vault_dir}")

      {:error, reason} ->
        Mix.raise("Failed to extract zip: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.raise("Usage: mix kyber.import.kyber <zip_path>")
  end
end
