defmodule MimirOrchestration.Passes.Policy do
  @moduledoc """
  Checks agent registry and tool allowlist membership at compile time.
  Unknown targets produce diagnostics before execution.
  """
  @behaviour MimirWorkflows.Compiler.Pass

  alias MimirWorkflows.{Diagnostic, Spec}

  @impl true
  def check(%Spec{steps: steps}, %MimirOrchestration.Policy{} = policy) do
    steps
    |> Enum.reject(&is_nil(&1.id))
    |> Enum.flat_map(&check_step(&1, policy))
  end

  defp check_step(%Spec.Step{id: id, kind: "agent", raw: %{"agent" => name}}, policy)
       when is_binary(name) do
    membership(policy.agent_registry, name, id, "agent", "registry")
  end

  defp check_step(%Spec.Step{id: id, kind: "tool", raw: %{"tool" => name}}, policy)
       when is_binary(name) do
    membership(policy.allowed_tools, name, id, "tool", "allowlist")
  end

  defp check_step(_step, _policy), do: []

  defp membership(set, name, step_id, label, list_label) do
    if Map.has_key?(set, name) do
      []
    else
      [error(step_id, "#{label} #{inspect(name)} is not in this tenant's #{list_label}")]
    end
  end

  defp error(step_id, message) do
    %Diagnostic{pass: :policy, severity: :error, step_id: step_id, message: message}
  end
end
