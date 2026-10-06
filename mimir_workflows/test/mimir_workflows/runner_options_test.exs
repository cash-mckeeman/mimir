defmodule MimirWorkflows.RunnerOptionsTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Runner
  alias MimirWorkflows.TestSteps.Crash

  defmodule Sleeper do
    @behaviour MimirWorkflows.Step
    @impl true
    def run(%{ms: ms} = params, _upstream) do
      Process.sleep(ms)
      {:ok, %{slept: ms, tag: params[:tag]}}
    end
  end

  defmodule Tracker do
    @behaviour MimirWorkflows.Step
    @impl true
    def run(%{agent: agent}, _upstream) do
      running = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      Process.sleep(30)
      Agent.update(agent, &(&1 - 1))
      {:ok, %{peak_seen: running}}
    end
  end

  defmodule LinkedExit do
    @behaviour MimirWorkflows.Step
    @impl true
    def run(%{reason: reason}, _upstream) do
      spawn_link(fn -> exit(reason) end)
      Process.sleep(:infinity)
    end
  end

  test "a crashing step reports its id" do
    steps = [%{id: "boom", module: Crash, params: %{}, depends_on: []}]

    assert {:error, {:step_crashed, "boom", {:error, %RuntimeError{message: "kaboom"}}}} =
             Runner.run(steps)
  end

  test "a timed-out step reports its id" do
    steps = [%{id: :slow, module: Sleeper, params: %{ms: :infinity}, depends_on: []}]
    assert {:error, {:step_crashed, :slow, :timeout}} = Runner.run(steps, timeout: 50)
  end

  test "a timeout in a shared phase names the slow step and its phase, not a sibling's" do
    handler =
      :telemetry_test.attach_event_handlers(self(), [[:mimir_workflows, :step, :exception]])

    wf = make_ref()

    # "slow" is neither first in its phase nor in phase 0.
    steps = [
      %{id: "root", module: Sleeper, params: %{ms: 0}, depends_on: []},
      %{id: "fast_a", module: Sleeper, params: %{ms: 0}, depends_on: ["root"]},
      %{id: "slow", module: Sleeper, params: %{ms: :infinity}, depends_on: ["root"]},
      %{id: "fast_b", module: Sleeper, params: %{ms: 0}, depends_on: ["root"]}
    ]

    assert {:error, {:step_crashed, "slow", :timeout}} =
             Runner.run(steps, timeout: 50, telemetry_meta: %{workflow_id: wf})

    assert_receive {[:mimir_workflows, :step, :exception], ^handler, _,
                    %{step_id: "slow", phase: 1, reason: :timeout, workflow_id: ^wf}}
  end

  test "a timed-out step closes its telemetry span with an exception event" do
    handler =
      :telemetry_test.attach_event_handlers(self(), [[:mimir_workflows, :step, :exception]])

    # Handlers are global and other files run concurrently; a unique marker
    # keeps this test and theirs from matching each other's events.
    wf = make_ref()
    steps = [%{id: :slow, module: Sleeper, params: %{ms: :infinity}, depends_on: []}]
    assert {:error, _} = Runner.run(steps, timeout: 50, telemetry_meta: %{workflow_id: wf})

    assert_receive {[:mimir_workflows, :step, :exception], ^handler, %{duration: d},
                    %{step_id: :slow, phase: 0, reason: :timeout, workflow_id: ^wf, run_ref: _}}

    assert d == System.convert_time_unit(50, :millisecond, :native)
  end

  test "a step whose linked process exits, under a trapping caller, reports and closes its span" do
    handler =
      :telemetry_test.attach_event_handlers(self(), [[:mimir_workflows, :step, :exception]])

    wf = make_ref()
    steps = [%{id: :linked, module: LinkedExit, params: %{reason: :linked_down}, depends_on: []}]

    # Without trap_exit the task's exit would take the test process down
    # with it instead of reaching the runner as {:exit, _}.
    trapping = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:step_crashed, :linked, :linked_down}} =
               Runner.run(steps, telemetry_meta: %{workflow_id: wf})
    after
      Process.flag(:trap_exit, trapping)
    end

    assert_receive {[:mimir_workflows, :step, :exception], ^handler, %{duration: d},
                    %{step_id: :linked, phase: 0, reason: :linked_down, workflow_id: ^wf}}

    assert is_integer(d) and d >= 0
  end

  test "max_concurrency caps in-phase parallelism" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    steps =
      for i <- 1..6, do: %{id: {:t, i}, module: Tracker, params: %{agent: agent}, depends_on: []}

    assert {:ok, results} = Runner.run(steps, max_concurrency: 2)
    assert results |> Map.values() |> Enum.map(& &1.peak_seen) |> Enum.max() <= 2
  end

  # A failing step and a slow sibling in one phase, and a step in the next phase.
  defp wave(owner) do
    [
      %{id: :fail, module: MimirWorkflows.TestSteps.Fail, params: %{}, depends_on: []},
      %{
        id: :slow,
        module: MimirWorkflows.TestSteps.SlowNotify,
        params: %{owner: owner, ms: 150, id: :slow},
        depends_on: []
      },
      %{
        id: :next,
        module: MimirWorkflows.TestSteps.SlowNotify,
        params: %{owner: owner, ms: 0, id: :next},
        depends_on: [:slow]
      }
    ]
  end

  describe ":halt" do
    test ":immediate, the default, stops the failing phase at once" do
      assert {:error, {:step_failed, :fail, :boom}} = Runner.run(wave(self()))
      refute_received {:finished, :slow}
    end

    test ":after_phase lets the failing phase finish, then stops" do
      assert {:error, {:step_failed, :fail, :boom}} = Runner.run(wave(self()), halt: :after_phase)
      assert_received {:finished, :slow}
      refute_received {:finished, :next}
    end

    test "any other value is refused" do
      assert_raise ArgumentError, ~r/:halt/, fn -> Runner.run(wave(self()), halt: :eventually) end
      assert_raise ArgumentError, ~r/:halt/, fn -> Runner.run([], halt: :bogus) end
    end
  end
end
