defmodule MimirOrchestration.PassesPolicyBudgetTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Passes, Policy}

  defp policy do
    %Policy{
      agent_registry: %{"data_analyst" => {:rma, "data_analyst"}},
      allowed_tools: %{"emit" => &Function.identity/1},
      budget_ceiling_microdollars: 1_000_000
    }
  end

  # Conform-to-engine: passes receive the parsed %MimirWorkflows.Spec{}.
  defp spec(steps) do
    {spec, _} =
      MimirWorkflows.Spec.parse(%{
        "name" => "wf",
        "version" => 1,
        "params" => [],
        "steps" => steps
      })

    spec
  end

  test "agent not in registry is a policy error" do
    diags =
      Passes.Policy.check(
        spec([%{"id" => "a", "kind" => "agent", "agent" => "rogue", "depends_on" => []}]),
        policy()
      )

    assert [d] = diags
    assert d.pass == :policy and d.step_id == "a" and d.message =~ "rogue"
  end

  test "tool not in allowlist is a policy error" do
    diags =
      Passes.Policy.check(
        spec([%{"id" => "a", "kind" => "tool", "tool" => "send_email", "depends_on" => []}]),
        policy()
      )

    assert Enum.any?(diags, &(&1.pass == :policy and &1.message =~ "send_email"))
  end

  test "declared step budgets exceeding the ceiling is a budget error" do
    steps = [
      %{
        "id" => "a",
        "kind" => "agent",
        "agent" => "data_analyst",
        "depends_on" => [],
        "descriptor" => %{"budget_ceiling_microdollars" => 900_000}
      },
      %{
        "id" => "b",
        "kind" => "llm",
        "prompt" => "x",
        "depends_on" => [],
        "descriptor" => %{"budget_ceiling_microdollars" => 200_000}
      }
    ]

    diags = Passes.Budget.check(spec(steps), policy())

    assert Enum.any?(
             diags,
             &(&1.pass == :budget and &1.severity == :error and &1.message =~ "1100000")
           )
  end

  test "routed step missing a budget is a warning; tool steps exempt" do
    steps = [
      %{"id" => "a", "kind" => "agent", "agent" => "data_analyst", "depends_on" => []},
      %{"id" => "t", "kind" => "tool", "tool" => "emit", "depends_on" => []}
    ]

    diags = Passes.Budget.check(spec(steps), policy())
    assert [w] = diags
    assert w.severity == :warning and w.step_id == "a"
  end

  test "nil ceiling skips the sum check but keeps warnings" do
    steps = [%{"id" => "a", "kind" => "llm", "prompt" => "x", "depends_on" => []}]
    diags = Passes.Budget.check(spec(steps), %{policy() | budget_ceiling_microdollars: nil})
    assert [%{severity: :warning}] = diags
  end
end
