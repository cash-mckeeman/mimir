defmodule MimirWorkflows.RunnerTelemetryTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Runner
  alias MimirWorkflows.TestSteps.{Echo, Fail}

  test "emits run and step spans with merged host metadata" do
    handler =
      :telemetry_test.attach_event_handlers(self(), [
        [:mimir_workflows, :run, :start],
        [:mimir_workflows, :run, :stop],
        [:mimir_workflows, :step, :start],
        [:mimir_workflows, :step, :stop]
      ])

    steps = [%{id: "a", module: Echo, params: %{}, depends_on: []}]
    assert {:ok, _} = Runner.run(steps, telemetry_meta: %{workflow_id: "wf_1"})

    assert_receive {[:mimir_workflows, :run, :start], ^handler, %{system_time: _},
                    %{workflow_id: "wf_1", run_ref: ref}}

    assert_receive {[:mimir_workflows, :step, :start], ^handler, _,
                    %{step_id: "a", phase: 0, workflow_id: "wf_1", run_ref: ^ref}}

    assert_receive {[:mimir_workflows, :step, :stop], ^handler, %{duration: d}, %{step_id: "a"}}
    assert is_integer(d)
    assert_receive {[:mimir_workflows, :run, :stop], ^handler, %{duration: _}, %{run_ref: ^ref}}
  end

  test "a failed step emits step exception and run stop with error status" do
    handler =
      :telemetry_test.attach_event_handlers(self(), [
        [:mimir_workflows, :step, :exception],
        [:mimir_workflows, :run, :stop]
      ])

    steps = [%{id: :bad, module: Fail, params: %{}, depends_on: []}]
    assert {:error, _} = Runner.run(steps)

    assert_receive {[:mimir_workflows, :step, :exception], ^handler, _,
                    %{step_id: :bad, reason: :boom}}

    assert_receive {[:mimir_workflows, :run, :stop], ^handler, _, %{status: :error}}
  end
end
