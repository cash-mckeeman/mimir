defmodule MimirOrchestration.EvalTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Eval, Policy}

  defp policy do
    %Policy{
      agent_registry: %{"a" => {:rma, "a"}},
      allowed_tools: %{"t" => &Function.identity/1},
      budget_ceiling_microdollars: 100
    }
  end

  test "clean minimal plan scores compiles: true with no dead steps" do
    spec = %{
      "name" => "w",
      "version" => 1,
      "params" => [],
      "steps" => [
        %{
          "id" => "s1",
          "kind" => "llm",
          "prompt" => "x",
          "depends_on" => [],
          "descriptor" => %{"budget_ceiling_microdollars" => 1}
        },
        %{
          "id" => "s2",
          "kind" => "tool",
          "tool" => "t",
          "input" => "{{s1}}",
          "depends_on" => ["s1"]
        }
      ]
    }

    assert %{compiles: true, errors: 0, warnings: 0, dead_steps: []} =
             Eval.plan_score(spec, policy())
  end

  test "a step nobody consumes is flagged dead" do
    spec = %{
      "name" => "w",
      "version" => 1,
      "params" => [],
      "steps" => [
        %{
          "id" => "used",
          "kind" => "llm",
          "prompt" => "x",
          "depends_on" => [],
          "descriptor" => %{"budget_ceiling_microdollars" => 1}
        },
        %{
          "id" => "orphan",
          "kind" => "llm",
          "prompt" => "y",
          "depends_on" => [],
          "descriptor" => %{"budget_ceiling_microdollars" => 1}
        },
        %{
          "id" => "final",
          "kind" => "tool",
          "tool" => "t",
          "input" => "{{used}}",
          "depends_on" => ["used"]
        }
      ]
    }

    assert %{compiles: true, dead_steps: ["orphan"]} = Eval.plan_score(spec, policy())
  end

  test "broken plan reports error count, compiles: false" do
    assert %{compiles: false, errors: e} = Eval.plan_score(%{"steps" => "junk"}, policy())
    assert e > 0
  end
end
