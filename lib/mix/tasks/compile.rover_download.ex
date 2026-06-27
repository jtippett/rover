defmodule Mix.Tasks.Compile.RoverDownload do
  @moduledoc false
  # Custom Mix compiler: download the precompiled `rover_runtime` binary for the
  # host target into priv/native/ at `mix compile`.
  #
  # Listed in mix.exs *after* `Mix.compilers()` so it runs once the :elixir
  # compiler has built `Rover.Precompiled` (the binary is a runtime port executable
  # — it isn't needed to compile Elixir, only to run a browser). On a clean build
  # this ordering avoids the bootstrap problem of a compiler that can't yet load
  # its own helper module.
  #
  # All the real work (and all the testable logic) lives in `Rover.Precompiled`;
  # this is the thin Mix shim. Set ROVER_BUILD=1 to skip the download and use a
  # local `cargo` build instead (see `Rover.Runtime`).
  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(_argv) do
    case Rover.Precompiled.ensure() do
      {:ok, archive} ->
        Mix.shell().info([:green, "* downloaded ", :reset, "rover_runtime (#{archive})"])
        {:ok, []}

      # Quiet for the expected skips (already installed, force-build, host we don't
      # ship). Note the ones that leave a supported consumer without a binary, so
      # they get a compile-time heads-up instead of a confusing runtime crash.
      {:skip, reason} when reason in [:already_present, :force_build, :unsupported_target] ->
        {:noop, []}

      {:skip, reason} ->
        Mix.shell().info([
          :yellow,
          "* rover_runtime not downloaded (#{inspect(reason)}). ",
          :reset,
          "It'll be built from source / ROVER_RUNTIME_BIN at runtime; ",
          "set ROVER_BUILD=1 to build now."
        ])

        {:noop, []}

      {:error, {archive, reason}} ->
        Mix.raise("""
        failed to download the precompiled rover_runtime (#{archive}): #{inspect(reason)}

        Work around it by either:

          * building locally:  ROVER_BUILD=1 mix compile  (needs the Rust toolchain
            and a Servo checkout — see `just servo` / `mix rover.build`), or
          * pointing ROVER_RUNTIME_BIN at an existing binary.
        """)
    end
  end
end
