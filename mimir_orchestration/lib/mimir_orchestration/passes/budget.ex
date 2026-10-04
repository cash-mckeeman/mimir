defmodule MimirOrchestration.Passes.Budget do
  @moduledoc """
  Checks the sum of declared agent and model step budgets against the policy
  ceiling. Missing budgets produce warnings. This is a static check, not a
  reservation or runtime enforcement. Hosts enforce runtime budgets through
  their agent runners and model-call transports.
  """
  @behaviour MimirWorkflows.Compiler.Pass

  alias MimirWorkflows.{Diagnostic, Spec}

  @impl true
  def check(%Spec{steps: steps}, %MimirOrchestration.Policy{} = policy) do
    routed =
      steps
      |> Enum.reject(&is_nil(&1.id))
      |> Enum.filter(&(&1.kind in ["agent", "llm"]))

    {declared, missing} = Enum.split_with(routed, &is_integer(step_budget(&1)))

    warnings =
      for s <- missing do
        %Diagnostic{
          pass: :budget,
          severity: :warning,
          step_id: s.id,
          message:
            "routed step declares no budget_ceiling_microdollars; router grant is the only bound"
        }
      end

    total = declared |> Enum.map(&step_budget/1) |> Enum.sum()
    ceiling = policy.budget_ceiling_microdollars

    over =
      if is_integer(ceiling) and total > ceiling do
        [
          %Diagnostic{
            pass: :budget,
            severity: :error,
            step_id: nil,
            message:
              "declared step budgets sum to #{total} microdollars, over the policy ceiling #{ceiling}"
          }
        ]
      else
        []
      end

    warnings ++ over
  end

  defp step_budget(%Spec.Step{raw: raw}),
    do: get_in(raw, ["descriptor", "budget_ceiling_microdollars"])
end
