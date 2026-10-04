defmodule MimirWorkflows.MixProject do
  use Mix.Project

  @app :mimir_workflows
  @version "0.7.0-dev"
  @source_url "https://github.com/cash-mckeeman/mimir"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Deterministic workflow engine for agent steps on the BEAM: " <>
          "declared-as-data DAGs, compile-time validation passes, phased parallel execution.",
      package: package(),
      docs: docs(),
      dialyzer: [plt_local_path: "priv/plts", plt_core_path: "priv/plts", plt_add_apps: [:ex_unit]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
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
