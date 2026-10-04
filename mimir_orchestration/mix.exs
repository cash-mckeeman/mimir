defmodule MimirOrchestration.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mimir_orchestration,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      sibling(:mimir_workflows),
      sibling(:mimir),
      {:req_managed_agents, "~> 0.10"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:jido, "~> 2.2", optional: true},
      {:req_llm, "~> 1.10", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Path in development; from Hex when publishing (MIMIR_PUBLISH=1), at the
  # family minor.
  defp sibling(app) do
    if System.get_env("MIMIR_PUBLISH") == "1" do
      %Version{major: major, minor: minor} = Version.parse!(@version)
      {app, "~> #{major}.#{minor}.0"}
    else
      {app, path: "../#{app}"}
    end
  end

  defp dialyzer do
    [
      # Keep PLTs under priv/plts so CI can cache them across runs.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # :ex_unit — several test doubles implement behaviours exercised only
      # under MIX_ENV=test; :mix covers any Mix.* calls in tooling.
      plt_add_apps: [:mix, :ex_unit]
    ]
  end
end
