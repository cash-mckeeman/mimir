defmodule MimirOrchestration.WorkflowsContractTest do
  @moduledoc """
  A compiled plan runs through mimir_workflows' reference runner: each step reaches
  it as a step spec in the phase its dependencies put it in, the run's workflow id
  rides on the workflows runner's events, and the plan's results come back keyed by
  step id.
  """
  use ExUnit.Case, async: false

  alias MimirOrchestration.{Compiler, Exec, NodeResult, Policy}

  defmodule Router do
    @behaviour MimirOrchestration.RouterClient
    @impl true
    def route(req, _opts),
      do:
        {:ok,
         %{
           "placement" => %{"model" => "m"},
           "grant" => %{"key" => "k"},
           "decision_id" => "d-#{req.step_id}"
         }}
  end

  defmodule StubAgent do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run({:ref, name}, _input, _opts), do: {:ok, %NodeResult{text: "out-#{name}", raw: %{}}}
  end

  @plan %{
    "name" => "chain",
    "version" => 1,
    "params" => ["q"],
    "steps" => [
      %{
        "id" => "one",
        "kind" => "agent",
        "agent" => "a",
        "input" => "{{params.q}}",
        "depends_on" => [],
        "descriptor" => %{"task_class" => "t", "budget_ceiling_microdollars" => 1}
      },
      %{
        "id" => "two",
        "kind" => "agent",
        "agent" => "a",
        "input" => "{{one}}",
        "depends_on" => ["one"],
        "descriptor" => %{"task_class" => "t", "budget_ceiling_microdollars" => 1}
      }
    ]
  }

  test "each compiled step runs as a workflows step, in its dependency phase" do
    owner = self()

    :telemetry.attach(
      "wf-contract",
      [:mimir_workflows, :step, :start],
      fn _e, _m, meta, _ -> send(owner, {:wf, meta.step_id, meta.phase, meta.workflow_id}) end,
      nil
    )

    {:ok, compiled} =
      Compiler.compile(@plan, %Policy{
        agent_registry: %{"a" => {:ref, "a"}},
        budget_ceiling_microdollars: 10
      })

    assert {:ok,
            %{
              results: %{"one" => %NodeResult{text: "out-a"}, "two" => %NodeResult{text: "out-a"}}
            }} =
             Exec.run(compiled, %{"q" => "go"},
               router: {Router, []},
               agent_runner: StubAgent,
               workflow_id: "wf-c"
             )

    assert_received {:wf, "one", 0, "wf-c"}
    assert_received {:wf, "two", 1, "wf-c"}
  after
    :telemetry.detach("wf-contract")
  end
end
