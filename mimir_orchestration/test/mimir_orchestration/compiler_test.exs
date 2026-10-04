defmodule MimirOrchestration.CompilerTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Compiled, Compiler, Policy}

  defp policy do
    %Policy{
      agent_registry: %{
        "data_analyst" => {:rma, "spec-da"},
        "business_analyst" => {:rma, "spec-ba"}
      },
      allowed_tools: %{"emit" => &Function.identity/1},
      budget_ceiling_microdollars: 1_000_000
    }
  end

  defp valid_spec do
    %{
      "name" => "wf",
      "version" => 1,
      "params" => ["q"],
      "steps" => [
        %{
          "id" => "analyze",
          "kind" => "agent",
          "agent" => "data_analyst",
          "input" => %{"question" => "{{params.q}}"},
          "descriptor" => %{"task_class" => "analysis", "budget_ceiling_microdollars" => 300_000},
          "depends_on" => []
        },
        %{
          "id" => "narrate",
          "kind" => "agent",
          "agent" => "business_analyst",
          "input" => "{{analyze}}",
          "runtime" => "local",
          "descriptor" => %{"task_class" => "narrative", "budget_ceiling_microdollars" => 300_000},
          "depends_on" => ["analyze"]
        }
      ]
    }
  end

  test "valid spec compiles; steps lowered atom-keyed with opaque targets" do
    assert {:ok, %Compiled{name: "wf", steps: [a, n], warnings: []}} =
             Compiler.compile(valid_spec(), policy())

    assert a.id == "analyze" and a.kind == "agent" and a.target == {:rma, "spec-da"}
    assert a.runtime == nil
    assert n.runtime == :local and n.depends_on == ["analyze"]
  end

  test "engine diagnostics (refs not covered by deps) surface through the façade" do
    spec =
      put_in(valid_spec()["steps"], [
        %{"id" => "a", "kind" => "llm", "prompt" => "x", "depends_on" => []},
        %{"id" => "b", "kind" => "llm", "prompt" => "{{a}}", "depends_on" => []}
      ])

    assert {:error, diags} = Compiler.compile(spec, policy())
    assert Enum.any?(diags, &(&1.pass == :refs and &1.step_id == "b"))
  end

  test "host diagnostics (kind + policy) accumulate with engine diagnostics" do
    spec =
      put_in(valid_spec()["steps"], [%{"id" => "a", "kind" => "magic", "depends_on" => ["ghost"]}])

    assert {:error, diags} = Compiler.compile(spec, policy())
    assert Enum.any?(diags, &(&1.pass == :kind)) and Enum.any?(diags, &(&1.pass == :dag))
  end

  test "budget warnings ride on Compiled.warnings" do
    spec =
      update_in(valid_spec()["steps"], fn [a, n] ->
        [update_in(a["descriptor"], &Map.delete(&1, "budget_ceiling_microdollars")), n]
      end)

    assert {:ok, %Compiled{warnings: [w]}} = Compiler.compile(spec, policy())
    assert w.pass == :budget and w.step_id == "analyze"
  end
end
