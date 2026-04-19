defmodule Rover.Runtime do
  @moduledoc false
  # Locate the `rover_runtime` binary for the current OS / architecture.
  #
  # Resolution order:
  #
  #   1. Environment variable `ROVER_RUNTIME_BIN` — absolute path. Useful for
  #      CI and local dev when the binary lives outside the project.
  #
  #   2. `priv/native/rover_runtime` — the release layout. When we ship
  #      precompiled binaries via GitHub Releases (see `Rover.Runtime.Download`
  #      in a future release), they land here.
  #
  #   3. `native/rover_runtime/target/release/rover_runtime` — release build
  #      via `mix rover.build`.
  #
  #   4. `native/rover_runtime/target/debug/rover_runtime` — dev build from
  #      `cargo build` without `--release`.
  #
  # The first resolution that exists and is executable wins.

  @binary_name "rover_runtime"

  @doc """
  Find the `rover_runtime` binary path, or raise with an actionable message.
  """
  @spec binary_path!() :: Path.t()
  def binary_path! do
    case binary_path() do
      {:ok, path} ->
        path

      :error ->
        raise Rover.Error,
          reason: :runtime,
          message: """
          could not locate the rover_runtime binary.

          Options:

            * Build it:  mix rover.build
            * Point at it with the ROVER_RUNTIME_BIN environment variable.
            * Install precompiled binaries (not yet available in 0.1).

          Looked in:
          #{candidates() |> Enum.map_join("\n", &"  - #{&1}")}
          """
    end
  end

  @spec binary_path() :: {:ok, Path.t()} | :error
  def binary_path do
    Enum.find_value(candidates(), :error, fn candidate ->
      if (candidate && File.regular?(candidate)) and executable?(candidate) do
        {:ok, candidate}
      end
    end)
  end

  defp candidates do
    app_priv =
      case :code.priv_dir(:rover) do
        {:error, :bad_name} -> nil
        path -> Path.join([to_string(path), "native", @binary_name])
      end

    [
      System.get_env("ROVER_RUNTIME_BIN"),
      app_priv,
      Path.expand("native/rover_runtime/target/release/#{@binary_name}", File.cwd!()),
      Path.expand("native/rover_runtime/target/debug/#{@binary_name}", File.cwd!())
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
