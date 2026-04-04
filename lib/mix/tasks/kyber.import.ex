defmodule Mix.Tasks.Kyber.Import.Openclaw do
  @shortdoc "Import an OpenClaw vault zip into ~/.kyber/vault (multi-agent layout)"
  @moduledoc """
  Import identity and memory files from an OpenClaw vault archive.

  In multi-agent layout:
  - Identity files → `vault/agents/<agent>/` (default: "liet")
  - Shared files (concepts, people, projects) → `vault/shared/`

  In legacy layout (no agents/ or shared/ dirs), behaves as before:
  - Identity files → `vault/identity/`
  - Memory files → `vault/memory/`

  ## Usage

      mix kyber.import.openclaw /path/to/openclaw-export.zip
      mix kyber.import.openclaw /path/to/openclaw-export.zip --agent-name liet

  """

  use Mix.Task

  @vault_dir Path.expand("~/.kyber/vault")
  @identity_files ~w(SOUL.md MEMORY.md USER.md TOOLS.md IDENTITY.md AGENTS.md)
  @shared_dirs ~w(concepts people projects)

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [agent_name: :string])
    agent_name = Keyword.get(opts, :agent_name, "liet")

    zip_path = case rest do
      [path] -> Path.expand(path)
      _ -> Mix.raise("Usage: mix kyber.import.openclaw <zip_path> [--agent-name NAME]")
    end

    unless File.exists?(zip_path) do
      Mix.raise("File not found: #{zip_path}")
    end

    layout = detect_layout()

    case layout do
      :multi_agent -> import_multi_agent(zip_path, agent_name)
      :legacy -> import_legacy(zip_path)
    end
  end

  defp detect_layout do
    cond do
      File.dir?(Path.join(@vault_dir, "agents")) -> :multi_agent
      File.dir?(Path.join(@vault_dir, "shared")) -> :multi_agent
      true -> :legacy
    end
  end

  defp import_multi_agent(zip_path, agent_name) do
    agent_dir = Path.join([@vault_dir, "agents", agent_name])
    shared_dir = Path.join(@vault_dir, "shared")
    File.mkdir_p!(agent_dir)
    File.mkdir_p!(shared_dir)

    # Create shared subdirs
    for dir <- @shared_dirs, do: File.mkdir_p!(Path.join(shared_dir, dir))

    # Create agent memory subdir
    File.mkdir_p!(Path.join(agent_dir, "memory"))

    tmp_dir = Path.join(System.tmp_dir!(), "kyber_import_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    try do
      Mix.shell().info("Extracting #{zip_path}...")

      case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(tmp_dir)}]) do
        {:ok, files} ->
          files = Enum.map(files, &to_string/1)

          # Import identity files to agent dir
          import_identity_files(files, agent_dir)

          # Import USER.md to shared dir (same human for both agents)
          import_shared_user(files, shared_dir)

          # Import memory files to agent memory dir
          import_memory_files(files, Path.join(agent_dir, "memory"))

          # Import shared dirs (concepts, people, projects)
          import_shared_dirs(files, shared_dir)

          Mix.shell().info("OpenClaw import complete → #{@vault_dir} (agent: #{agent_name})")

        {:error, reason} ->
          Mix.raise("Failed to extract zip: #{inspect(reason)}")
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp import_legacy(zip_path) do
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

  defp import_identity_files(files, dest_dir) do
    for name <- @identity_files do
      case find_file(files, name) do
        nil -> Mix.shell().info("  #{name} not found in archive")
        path -> copy_file(path, Path.join(dest_dir, name), name)
      end
    end
  end

  defp import_shared_user(files, shared_dir) do
    case find_file(files, "USER.md") do
      nil -> :ok
      path ->
        copy_file(path, Path.join(shared_dir, "USER.md"), "shared/USER.md")
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

  defp import_shared_dirs(files, shared_dir) do
    for dir_name <- @shared_dirs do
      dir_files =
        Enum.filter(files, fn f ->
          String.contains?(f, "/#{dir_name}/") && String.ends_with?(f, ".md") && File.regular?(f)
        end)

      for file <- dir_files do
        basename = Path.basename(file)
        dest = Path.join([shared_dir, dir_name, basename])
        copy_file(file, dest, "shared/#{dir_name}/#{basename}")
      end
    end
  end

  defp find_file(files, name) do
    Enum.find(files, &String.ends_with?(&1, "/#{name}")) ||
      Enum.find(files, &(Path.basename(&1) == name))
  end

  defp copy_file(src, dest, label) do
    File.cp!(src, dest)
    Mix.shell().info("  Imported #{label}")
  end
end

defmodule Mix.Tasks.Kyber.Import.Kyber do
  @shortdoc "Import a Kyber vault zip into ~/.kyber/vault (multi-agent layout)"
  @moduledoc """
  Import an existing Kyber vault archive into ~/.kyber/vault/.

  In multi-agent layout:
  - Identity files → `vault/agents/<agent>/` (default: "stilgar")
  - Shared files → `vault/shared/`

  In legacy layout, extracts directly into vault dir.

  ## Usage

      mix kyber.import.kyber /path/to/kyber-vault.zip
      mix kyber.import.kyber /path/to/kyber-vault.zip --agent-name stilgar

  """

  use Mix.Task

  @vault_dir Path.expand("~/.kyber/vault")
  @identity_files ~w(SOUL.md MEMORY.md TOOLS.md AGENTS.md)
  @shared_dirs ~w(concepts people projects)

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [agent_name: :string])
    agent_name = Keyword.get(opts, :agent_name, "stilgar")

    zip_path = case rest do
      [path] -> Path.expand(path)
      _ -> Mix.raise("Usage: mix kyber.import.kyber <zip_path> [--agent-name NAME]")
    end

    unless File.exists?(zip_path) do
      Mix.raise("File not found: #{zip_path}")
    end

    layout = detect_layout()

    case layout do
      :multi_agent -> import_multi_agent(zip_path, agent_name)
      :legacy -> import_legacy(zip_path)
    end
  end

  defp detect_layout do
    cond do
      File.dir?(Path.join(@vault_dir, "agents")) -> :multi_agent
      File.dir?(Path.join(@vault_dir, "shared")) -> :multi_agent
      true -> :legacy
    end
  end

  defp import_multi_agent(zip_path, agent_name) do
    agent_dir = Path.join([@vault_dir, "agents", agent_name])
    shared_dir = Path.join(@vault_dir, "shared")
    File.mkdir_p!(agent_dir)
    File.mkdir_p!(shared_dir)
    for dir <- @shared_dirs, do: File.mkdir_p!(Path.join(shared_dir, dir))
    File.mkdir_p!(Path.join(agent_dir, "memory"))

    tmp_dir = Path.join(System.tmp_dir!(), "kyber_import_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    try do
      Mix.shell().info("Extracting #{zip_path}...")

      case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(tmp_dir)}]) do
        {:ok, files} ->
          files = Enum.map(files, &to_string/1)

          # Identity files to agent dir
          for name <- @identity_files do
            case find_file(files, name) do
              nil -> :ok
              path -> copy_file(path, Path.join(agent_dir, name), "agents/#{agent_name}/#{name}")
            end
          end

          # USER.md to shared
          case find_file(files, "USER.md") do
            nil -> :ok
            path -> copy_file(path, Path.join(shared_dir, "USER.md"), "shared/USER.md")
          end

          # Memory files to agent memory dir
          memory_files =
            Enum.filter(files, fn f ->
              String.contains?(f, "/memory/") && String.ends_with?(f, ".md") && File.regular?(f)
            end)

          for file <- memory_files do
            basename = Path.basename(file)
            copy_file(file, Path.join([agent_dir, "memory", basename]), "agents/#{agent_name}/memory/#{basename}")
          end

          # Shared dirs
          for dir_name <- @shared_dirs do
            dir_files =
              Enum.filter(files, fn f ->
                String.contains?(f, "/#{dir_name}/") && String.ends_with?(f, ".md") && File.regular?(f)
              end)

            for file <- dir_files do
              basename = Path.basename(file)
              copy_file(file, Path.join([shared_dir, dir_name, basename]), "shared/#{dir_name}/#{basename}")
            end
          end

          Mix.shell().info("Kyber import complete → #{@vault_dir} (agent: #{agent_name})")

        {:error, reason} ->
          Mix.raise("Failed to extract zip: #{inspect(reason)}")
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp import_legacy(zip_path) do
    File.mkdir_p!(@vault_dir)

    Mix.shell().info("Extracting #{zip_path} → #{@vault_dir}...")

    case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(@vault_dir)}]) do
      {:ok, files} ->
        Mix.shell().info("Imported #{length(files)} files → #{@vault_dir}")

      {:error, reason} ->
        Mix.raise("Failed to extract zip: #{inspect(reason)}")
    end
  end

  defp find_file(files, name) do
    Enum.find(files, &String.ends_with?(&1, "/#{name}")) ||
      Enum.find(files, &(Path.basename(&1) == name))
  end

  defp copy_file(src, dest, label) do
    File.cp!(src, dest)
    Mix.shell().info("  Imported #{label}")
  end
end
