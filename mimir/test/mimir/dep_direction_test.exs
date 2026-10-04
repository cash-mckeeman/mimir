defmodule Mimir.DepDirectionTest do
  @moduledoc """
  Guards declared dependencies and all module references in `lib/`, including prose.
  Dependencies scoped with `only:` are excluded from the declared sets.
  """
  use ExUnit.Case, async: true

  @runtime [:jason, :req, :telemetry]
  @optional []
  @forbidden [
    ~r/\bReqManagedAgents\./,
    ~r/\bMimirWorkflows\./,
    ~r/\bMimirOrchestration\./,
    ~r/\bMimirAnalytics\./,
    ~r/\bMimirGateway\./,
    ~r/\bEcto\./,
    ~r/\bPhoenix\./
  ]

  test "declared runtime dependencies are exactly req, jason and telemetry" do
    assert {runtime(), optional()} == {@runtime, @optional}
  end

  test "lib/ names no module of a package mimir must not depend on" do
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
