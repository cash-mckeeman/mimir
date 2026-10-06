defmodule MimirOrchestration.DepDirectionTest do
  @moduledoc """
  Guards declared dependencies and all module references in `lib/`, including prose.
  Dependencies scoped with `only:` are excluded from the declared sets.
  """
  use ExUnit.Case, async: true

  @runtime [:jason, :mimir, :mimir_workflows, :telemetry]
  @optional if System.get_env("MIMIR_WITHOUT_RMA") == "1",
              do: [:jido, :req_llm],
              else: [:jido, :req_llm, :req_managed_agents]
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
    files = Path.wildcard("lib/**/*.ex")
    assert files != [], "the lib/**/*.ex glob matched no files: wrong working directory?"

    for {_re, home} <- @confined do
      assert home in files, "#{home} is not among the #{length(files)} scanned files"
    end

    offenders =
      for {re, home} <- @confined,
          path <- files,
          path != home,
          Regex.match?(re, File.read!(path)),
          do: {path, Regex.source(re)}

    assert offenders == [], "found in #{length(files)} scanned files"
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
