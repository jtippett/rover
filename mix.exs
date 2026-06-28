defmodule Rover.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jtippett/rover"

  def project do
    [
      app: :rover,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # `:rover_download` runs *after* the standard compilers: it fetches the
      # precompiled rover_runtime port binary into priv/native/ (see
      # Mix.Tasks.Compile.RoverDownload). The binary is only needed at runtime, so
      # it can land after Elixir is compiled. ROVER_BUILD=1 skips it.
      compilers: Mix.compilers() ++ [:rover_download],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      name: "Rover",
      aliases: aliases(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      # :inets/:ssl/:public_key back the precompiled-binary download performed by
      # the :rover_download Mix compiler (see Rover.Precompiled.fetch_body/1).
      extra_applications: [:logger, :inets, :ssl, :public_key]
    ]
  end

  defp deps do
    [
      {:msgpax, "~> 2.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.0"},

      # dev / test
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Drive the Servo web engine from Elixir. One OS process per browser, with " <>
      "per-instance proxy config, cookies, JS evaluation, and input automation."
  end

  defp package do
    [
      maintainers: ["James Tippett"],
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      # Ship the checksum file + Rust sources so consumers on unsupported targets
      # (or with ROVER_BUILD=1) can build rover_runtime from source.
      files: ~w(lib native/rover_runtime/src native/rover_runtime/Cargo.toml
           native/rover_runtime/Cargo.lock checksum-rover_runtime.exs
           mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Rover",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      "rover.build": ["cmd --cd native/rover_runtime cargo build --release"],
      "rover.build.dev": ["cmd --cd native/rover_runtime cargo build"]
    ]
  end
end
