defmodule MimirOrchestration.DepDirectionTest do
  @moduledoc """
  Guards declared dependencies and all module references in `lib/`, including prose.
  Dependencies scoped with `only:` are excluded from the declared sets.
  """
  use ExUnit.Case, async: true

  @runtime [:jason, :mimir, :mimir_workflows, :req_managed_agents, :telemetry]
  @optional [:jido, :req_llm]
  @confined [
    {~r/\bReqManagedAgents\./, "lib/mimir_orchestration/agent_runner/rma.ex"},
    {~r/\bJido\./, "lib/mimir_orchestration/agent_tool.ex"},
    {~r/\bReqLLM\./, "lib/mimir_orchestration/steps/llm_step.ex"}
  ]
  @forbidden [
    ~r/\bOban/,
    ~r/\bMimirAnalytics\./,
    ~r/\bMimirGateway\./,
    ~r/\bManagedAgents\./,
    ~r/\bBizinsights/,
    ~r/\bElixirGraph\./
  ]

  test "declared dependencies: in-house exactly mimir and mimir_workflows" do
    assert {runtime(), optional()} == {@runtime, @optional}
  end

  test "runtime adapter references are confined to their integration files" do
    offenders =
      for {re, home} <- @confined,
          path <- Path.wildcard("lib/**/*.ex"),
          path != home,
          Regex.match?(re, File.read!(path)),
          do: {path, Regex.source(re)}

    assert offenders == []
  end

  test "lib/ names no durable engine, host application or gateway" do
    assert offenders() == []
  end

  defp declared do
    Enum.reject(Mix.Project.config()[:deps], &Keyword.has_key?(opts(&1), :only))
  end

  defp runtime, do: for(d <- declared(), !opts(d)[:optional], do: elem(d, 0)) |> Enum.sort()
  defp optional, do: for(d <- declared(), opts(d)[:optional], do: elem(d, 0)) |> Enum.sort()

  defp opts({_app, opts}) when is_list(opts), do: opts
  defp opts({_app, _requirement}), do: []
  defp opts({_app, _requirement, opts}), do: opts

  defp offenders do
    for path <- Path.wildcard("lib/**/*.ex"),
        source = File.read!(path),
        re <- @forbidden,
        Regex.match?(re, source),
        do: {path, Regex.source(re)}
  end
end
