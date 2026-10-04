defmodule MimirOrchestration.Passes.Kind do
  @moduledoc """
  Validates agent, tool and model step kinds and their required fields.

  Receives a parsed `MimirWorkflows.Spec`; host fields remain in each step's
  `raw` map. Runtime names are checked against the supported vocabulary.
  """
  @behaviour MimirWorkflows.Compiler.Pass

  alias MimirWorkflows.{Diagnostic, Spec}

  @kinds ~w(agent tool llm)
  @runtimes ~w(local managed agentcore_harness self_managed)
  @kind_field %{"agent" => "agent", "tool" => "tool", "llm" => "prompt"}

  @impl true
  def check(%Spec{steps: steps}, _ctx) do
    steps
    |> Enum.reject(&is_nil(&1.id))
    |> Enum.flat_map(&check_step/1)
  end

  defp check_step(%Spec.Step{id: id, kind: kind, raw: raw}) do
    kind_diags =
      case kind do
        k when k in @kinds ->
          field = @kind_field[k]

          if is_binary(raw[field]),
            do: [],
            else: [error(id, "kind #{inspect(k)} requires string #{inspect(field)}")]

        other ->
          [error(id, "unknown step kind #{inspect(other)}")]
      end

    runtime_diags =
      case raw["runtime"] do
        nil -> []
        rt when rt in @runtimes -> []
        rt -> [error(id, "invalid runtime #{inspect(rt)}; one of #{inspect(@runtimes)}")]
      end

    kind_diags ++ runtime_diags
  end

  defp error(step_id, message) do
    %Diagnostic{pass: :kind, severity: :error, step_id: step_id, message: message}
  end
end
