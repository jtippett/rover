defmodule Mix.Tasks.Rover.Runtime.Download do
  @shortdoc "(Re)generate checksum-rover_runtime.exs from a published release's artifacts"
  @moduledoc """
  Download the released `rover_runtime` tarballs for the current `@version` and
  write their sha256 checksums to `#{Rover.Precompiled.checksum_file()}`.

  Run this *after* the `release.yml` build matrix has attached the per-target
  tarballs to the GitHub release (see UPDATE_PROCEDURE.md). The `:rover_download`
  compiler verifies downloads against the file this produces.

      mix rover.runtime.download --all --print

  Options:

    * `--all`   — fetch every supported target (default: just the host target)
    * `--print` — also print the generated checksum map to stdout
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, switches: [all: :boolean, print: :boolean])

    version = Mix.Project.config()[:version]

    targets =
      if opts[:all] do
        Rover.Precompiled.targets()
      else
        case Rover.Precompiled.target() do
          {:ok, triple} ->
            [triple]

          :unsupported ->
            Mix.raise("host target is unsupported; pass --all to fetch every target instead")
        end
      end

    Mix.shell().info(
      "Fetching rover_runtime checksums for v#{version} (#{Enum.join(targets, ", ")}) ..."
    )

    {oks, errors} =
      targets
      |> Enum.map(&Rover.Precompiled.fetch_checksum(version, &1))
      |> Enum.split_with(&match?({:ok, _}, &1))

    unless errors == [] do
      Mix.raise(
        "failed to fetch some artifacts:\n" <>
          Enum.map_join(errors, "\n", fn {:error, {t, r}} -> "  - #{t}: #{inspect(r)}" end)
      )
    end

    map = Map.new(oks, fn {:ok, {name, sha}} -> {name, sha} end)
    rendered = Rover.Precompiled.render_checksums(map)

    path = Rover.Precompiled.checksum_file()
    File.write!(path, rendered)
    Mix.shell().info([:green, "* wrote ", :reset, "#{path} (#{map_size(map)} target(s))"])

    if opts[:print], do: Mix.shell().info("\n" <> rendered)
  end
end
