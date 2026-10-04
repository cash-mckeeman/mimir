defmodule MimirOrchestration.MixProject do
  use Mix.Project

  @version "0.7.0-dev"

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

  # Path in development; from Hex when publishing. The requirement is the family
  # minor unless a patch needs a sibling's patch, which passes its own floor:
  # sibling(:mimir, "~> 0.7.1"). MIMIR_PUBLISH=1 gives the Hex range; "floor"
  # pins the lowest version that range admits (the publish guard uses it to test
  # a patch against its oldest siblings; nothing is published with it); any other
  # value, unset included, is the path dependency.
  defp sibling(app, requirement \\ nil) do
    case System.get_env("MIMIR_PUBLISH") do
      "1" -> {app, requirement || family_minor()}
      "floor" -> {app, "== " <> requirement_floor(requirement || family_minor())}
      _ -> {app, path: "../#{app}"}
    end
  end

  defp family_minor do
    %Version{major: major, minor: minor} = Version.parse!(@version)
    "~> #{major}.#{minor}.0"
  end

  # "~> 0.7.1" -> "0.7.1". Any other form fails here. Not named floor/1, which
  # clashes with the auto-imported Kernel.floor/1.
  defp requirement_floor("~> " <> version) do
    {:ok, _} = Version.parse(version)
    version
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
