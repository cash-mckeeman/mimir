defmodule Integration.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :integration,
      version: "0.0.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["test/support"]
  defp elixirc_paths(_), do: []

  defp deps do
    [
      {:mimir, path: "../mimir"},
      {:mimir_workflows, path: "../mimir_workflows"},
      {:mimir_orchestration, path: "../mimir_orchestration"},
      {:mimir_analytics, path: "../mimir_analytics"},
      {:req_managed_agents, ">= 0.14.0 and < 0.15.0", only: :test},
      {:req_llm, "~> 1.10", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
