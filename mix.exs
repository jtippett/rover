defmodule Rover.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jamestippett/rover"

  def project do
    [
      app: :rover,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
      extra_applications: [:logger]
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
      links: %{"GitHub" => @source_url},
      files: ~w(lib native/rover_runtime/src native/rover_runtime/Cargo.toml
           mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Rover",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp aliases do
    [
      "rover.build": ["cmd --cd native/rover_runtime cargo build --release"],
      "rover.build.dev": ["cmd --cd native/rover_runtime cargo build"]
    ]
  end
end
