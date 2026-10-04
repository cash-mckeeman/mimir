defmodule MimirAnalytics.MixProject do
  use Mix.Project

  def project do
    [
      app: :mimir_analytics,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
end
