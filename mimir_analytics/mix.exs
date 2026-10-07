defmodule MimirAnalytics.MixProject do
  use Mix.Project

  @app :mimir_analytics
  @version "0.7.0"
  @source_url "https://github.com/cash-mckeeman/mimir"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @source_url,
      description: "DuckDB run records, correlation, and cost views",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:duckdbex, "~> 0.4.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # Req.Test stubs need Plug; test-only.
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # :ex_unit — fixtures/support helpers import ExUnit.Assertions and CI
      # dialyzes under MIX_ENV=test; :mix covers Mix.Task modules.
      plt_add_apps: [:mix, :ex_unit]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/schema.sql priv/views.sql mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_url: @source_url,
      source_ref: source_ref(),
      source_url_pattern: "#{@source_url}/blob/#{source_ref()}/#{@app}/%{path}#L%{line}"
    ]
  end

  # The tag that publishes this version: vX.Y.0 for a lockstep minor,
  # <app>-vX.Y.Z for a one-package patch.
  defp source_ref do
    case Version.parse!(@version) do
      %Version{patch: 0} -> "v#{@version}"
      _ -> "#{@app}-v#{@version}"
    end
  end
end
