defmodule Mimir.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/cash-mckeeman/mimir"

  def project do
    [
      app: :mimir,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Embeddable routing oracle, pricing, and decision vocabulary for LLM workloads",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      name: "Mimir",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/pricing examples mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md", "CHANGELOG.md", "LICENSE"]]
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # Mix tasks call Mix.shell/Mix.raise; Mix isn't in the core PLT.
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
