defmodule MimirOrchestration.Compiler do
  @moduledoc """
  Compiles workflow data against a host policy.

  Schema, dependency and reference diagnostics accumulate with kind, registry
  and budget checks. A successful compile returns lowered steps with opaque
  targets resolved from the policy; invalid plans return diagnostics.
  """
  alias MimirOrchestration.{Compiled, Passes, Policy}

  @runtime_atoms %{
    "local" => :local,
    "managed" => :managed,
    "agentcore_harness" => :agentcore_harness,
    "self_managed" => :self_managed
  }

  @spec compile(map(), Policy.t()) ::
          {:ok, Compiled.t()} | {:error, [MimirWorkflows.Diagnostic.t()]}
  def compile(spec_map, %Policy{} = policy) do
    # Conform-to-engine: host passes are {module, ctx} tuples; success is a
    # 3-tuple {:ok, %Spec{}, warnings}.
    case MimirWorkflows.Compiler.compile(spec_map,
           passes: [{Passes.Kind, policy}, {Passes.Policy, policy}, {Passes.Budget, policy}]
         ) do
      {:ok, _engine_spec, warnings} -> {:ok, lower(spec_map, policy, warnings)}
      {:error, diags} -> {:error, diags}
    end
  end

  defp lower(spec_map, policy, warnings) do
    steps = spec_map |> Map.get("steps", []) |> List.wrap() |> Enum.filter(&is_map/1)

    %Compiled{
      name: spec_map["name"],
      version: spec_map["version"],
      params: List.wrap(spec_map["params"]),
      warnings: warnings,
      steps:
        Enum.map(steps, fn s ->
          %{
            id: s["id"],
            kind: s["kind"],
            target: target(s, policy),
            input_template: s["input"] || s["prompt"],
            descriptor: s["descriptor"] || %{},
            depends_on: s["depends_on"] || [],
            runtime: @runtime_atoms[s["runtime"]]
          }
        end)
    }
  end

  defp target(%{"kind" => "agent", "agent" => name}, policy), do: policy.agent_registry[name]
  defp target(%{"kind" => "tool", "tool" => name}, policy), do: policy.allowed_tools[name]
  defp target(_, _), do: nil
end
