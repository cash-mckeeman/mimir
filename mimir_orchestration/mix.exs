defmodule MimirOrchestration.MixProject do
  use Mix.Project

  @app :mimir_orchestration
  @version "0.7.0-dev"
  @source_url "https://github.com/cash-mckeeman/mimir"

  # req_managed_agents is optional, with a tested range. The ceiling moves only after
  # CI has run the suite against the new release, in a patch of this package alone.
  @rma_range ">= 0.10.0 and < 0.11.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @source_url,
      description: "Routing and budget contracts for agent workflows",
      package: package(),
      docs: docs(),
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
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:jido, "~> 2.2", optional: true},
      {:req_llm, "~> 1.10", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ] ++ rma_dep()
  end

  # MIMIR_WITHOUT_RMA=1 removes it from the dependency graph (CI's without-RMA leg);
  # MIMIR_RMA_PIN=<version> pins one release inside the range (CI's range legs).
  defp rma_dep do
    cond do
      System.get_env("MIMIR_WITHOUT_RMA") == "1" ->
        []

      pin = System.get_env("MIMIR_RMA_PIN") ->
        Version.match?(pin, @rma_range) ||
          Mix.raise("MIMIR_RMA_PIN #{pin} is outside #{@rma_range}")

        [{:req_managed_agents, "== " <> pin, optional: true}]

      true ->
        [{:req_managed_agents, @rma_range, optional: true}]
    end
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

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
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
