defmodule MimirOrchestration.DepDirectionTest do
  use ExUnit.Case, async: true

  @lib_files Path.wildcard("lib/**/*.ex")

  test "no host-application modules leak into the library" do
    offenders =
      for f <- @lib_files,
          src = File.read!(f),
          Regex.match?(~r/\bManagedAgents\.|\bBizinsights|\bElixirGraph\./, src),
          do: f

    assert offenders == [], "app-domain references found in: #{inspect(offenders)}"
  end

  test "Jido only in agent_tool.ex; ReqLLM only in llm_step.ex" do
    offenders =
      for f <- @lib_files,
          not String.ends_with?(f, "agent_tool.ex"),
          src = File.read!(f),
          Regex.match?(~r/\bJido\./, src),
          do: {f, :jido}

    offenders2 =
      for f <- @lib_files,
          not String.ends_with?(f, "llm_step.ex"),
          src = File.read!(f),
          Regex.match?(~r/\bReqLLM\./, src),
          do: {f, :req_llm}

    assert offenders ++ offenders2 == []
  end
end
