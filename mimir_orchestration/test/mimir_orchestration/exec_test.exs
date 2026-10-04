defmodule MimirOrchestration.ExecTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Compiled, Compiler, Exec, NodeResult, Policy}

  defmodule Router do
    @behaviour MimirOrchestration.RouterClient
    @impl true
    def route(req, _opts) do
      {:ok,
       %{
         "placement" => %{"model" => "fleet-fast"},
         "grant" => %{"key" => "k"},
         "decision_id" => "d-#{req.step_id}"
       }}
    end
  end

  defmodule StubRunner do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run({:rma, name}, input, opts) do
      send(opts[:owner] || self(), {:agent_run, name, input, opts[:metadata]})
      {:ok, %NodeResult{text: "out-#{name}", stop_reason: "end_turn", raw: %{}}}
    end
  end

  defp compiled do
    spec = %{
      "name" => "wf",
      "version" => 1,
      "params" => ["q"],
      "steps" => [
        %{
          "id" => "analyze",
          "kind" => "agent",
          "agent" => "stub",
          "input" => %{"question" => "{{params.q}}"},
          "depends_on" => [],
          "descriptor" => %{"task_class" => "analysis", "budget_ceiling_microdollars" => 1}
        },
        %{
          "id" => "shout",
          "kind" => "tool",
          "tool" => "upcase",
          "input" => "{{analyze}}",
          "depends_on" => ["analyze"]
        }
      ]
    }

    policy = %Policy{
      agent_registry: %{"stub" => {:rma, "stub"}},
      allowed_tools: %{
        "upcase" => fn %NodeResult{text: t} -> {:ok, %{"text" => String.upcase(t)}} end
      },
      budget_ceiling_microdollars: 10
    }

    {:ok, compiled} = Compiler.compile(spec, policy)
    compiled
  end

  test "agent output flows into the tool step; results are unwrapped" do
    assert {:ok, %{results: results}} =
             Exec.run(compiled(), %{"q" => "kpis"},
               router: {Router, []},
               agent_runner: StubRunner,
               agent_runner_opts: [owner: self()]
             )

    assert results["analyze"].text == "out-stub"
    assert results["shout"] == %{"text" => "OUT-STUB"}
    assert_receive {:agent_run, "stub", %{"question" => "kpis"}, %{step_id: "analyze"}}
  end

  test "unknown params are rejected before any step runs" do
    assert {:error, {:missing_params, ["q"]}} =
             Exec.run(compiled(), %{}, router: {Router, []}, agent_runner: StubRunner)
  end

  test "an unresolved ref in a compiled plan is a clean step_failed error, not a crashed task" do
    # Compiler.compile's refs pass rejects dangling refs before they ever
    # reach Exec — so this hand-builds a %Compiled{} the way a stale/foreign
    # compiler (or a bug elsewhere) could: a step whose input_template
    # references a ref nothing produced. Exec.run does not re-validate refs;
    # Template.resolve fails at dispatch time, and that must not crash the
    # Task.async_stream task it runs inside.
    compiled = %Compiled{
      name: "bad",
      version: 1,
      params: [],
      steps: [
        %{
          id: "s1",
          kind: "tool",
          target: fn _ -> {:ok, :never_called} end,
          input_template: "{{ghost}}",
          descriptor: %{},
          depends_on: []
        }
      ]
    }

    assert {:error, {:step_failed, "s1", {:unresolved_ref, "ghost"}}} =
             Exec.run(compiled, %{}, router: {Router, []})
  end
end
