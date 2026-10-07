defmodule MimirOrchestration.RunnerTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Runner, StepCall, StepInput}
  alias MimirOrchestration.Test.Registered

  defmodule FakeRouter do
    @behaviour Mimir.RouterClient
    @impl true
    def route(req, opts) do
      if name = opts[:capture], do: send(name, {:router_request, req.step_id, req})

      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "placement" => %{"model" => "fleet-fast", "lane" => "test"},
        "grant" => %{"key" => "sk-test", "budget_microdollars" => 100_000},
        "decision_id" => "decision-#{req.step_id}"
      })
    end
  end

  defp run_opts(extra),
    do:
      Keyword.merge(
        [router: {FakeRouter, [capture: Registered.self_name()]}, workflow_id: "wf-t"],
        extra
      )

  # :run MFAs; `to` is a registered name.
  def did(%StepCall{input: input}), do: {:ok, {:did, input}}
  def echo(%StepCall{input: input}), do: {:ok, input}
  def never(%StepCall{}), do: flunk("must not dispatch")
  def bad_return(%StepCall{}), do: :done
  def exit_boom(%StepCall{}), do: exit(:boom)

  def report_input(%StepCall{input: input, opts: opts}, to) do
    send(to, {:input, opts[:metadata][:step_id], input})
    {:ok, "r-" <> opts[:metadata][:step_id]}
  end

  def report_opts(%StepCall{opts: opts}, to) do
    send(to, {:ran, opts})
    {:ok, :done}
  end

  def fail_on_boom(%StepCall{input: :boom}), do: {:error, :kaput}
  def fail_on_boom(%StepCall{input: input}), do: {:ok, input}

  def sleep(%StepCall{}, ms) do
    Process.sleep(ms)
    {:ok, :late}
  end

  def drain(%StepCall{input: :fail}), do: {:error, :kaput}

  def drain(%StepCall{input: {:sleep, ms, value}}) do
    Process.sleep(ms)
    {:ok, value}
  end

  def drain(%StepCall{input: input}), do: {:ok, input}

  # Announces itself and holds until released, counting how many run at once.
  def gated(%StepCall{input: input}, to, counter) do
    Agent.update(counter, fn %{running: r, peak: p} -> %{running: r + 1, peak: max(p, r + 1)} end)
    send(to, {:started, self()})
    receive do: (:go -> :ok)
    Agent.update(counter, fn %{running: r} = state -> %{state | running: r - 1} end)
    {:ok, input}
  end

  test "waves execute in dependency order; results keyed by id" do
    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:ok, %{results: %{"a" => {:did, 1}, "b" => {:did, 2}}, workflow_id: "wf-t"}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :did, []}))
  end

  test "a StepInput is resolved at dispatch against completed results and the params" do
    steps = [
      %{id: "a", target: :t, input: "static", descriptor: %{}, depends_on: []},
      %{
        id: "b",
        target: :t,
        descriptor: %{},
        depends_on: ["a"],
        input: %StepInput{template: ["got", "{{a}}", "{{params.q}}"]}
      }
    ]

    run = {__MODULE__, :report_input, [Registered.self_name()]}
    assert {:ok, _} = Runner.run(steps, run_opts(run: run, params: %{"q" => "why"}))
    assert_receive {:input, "a", "static"}
    assert_receive {:input, "b", ["got", "r-a", "why"]}
  end

  test "route: false skips the router and passes correlation metadata only" do
    steps = [%{id: "t1", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} =
             Runner.run(
               steps,
               run_opts(run: {__MODULE__, :report_opts, [Registered.self_name()]})
             )

    assert_receive {:ran, opts}
    assert opts[:metadata][:step_id] == "t1"
    refute Keyword.has_key?(opts, :model)
    refute_receive {:router_request, "t1", _}, 50
  end

  test "step failure halts remaining waves" do
    steps = [
      %{id: "a", target: :t, input: :boom, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:error, {:step_failed, "a", :kaput}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :fail_on_boom, []}))
  end

  describe "a placement with a grant" do
    defmodule TypedRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(req, _opts) do
        Mimir.RouteResponse.new(%{
          "verdict" => "placement",
          "decision_id" => "dec-#{req.step_id}",
          "placement" => %{"model" => "fleet-fast", "lane" => "bedrock", "runtime" => "local"},
          "grant" => %{
            "key" => "sk-grant",
            "budget_microdollars" => 5_000,
            "expires_at" => "2026-07-09T00:00:00Z"
          }
        })
      end
    end

    test "dispatch gets turn_guard and decision_id metadata" do
      steps = [
        %{id: "a", target: :t, input: 1, descriptor: %{"task_class" => "t"}, depends_on: []}
      ]

      assert {:ok, _} =
               Runner.run(steps,
                 router: {TypedRouter, []},
                 run: {__MODULE__, :report_opts, [Registered.self_name()]},
                 workflow_id: "wf"
               )

      assert_receive {:ran, opts}
      assert is_function(opts[:turn_guard], 1)
      assert opts[:metadata][:decision_id] == "dec-a"
      assert opts[:metadata][:mimir_request_id] == "dec-a"
      assert :cont == opts[:turn_guard].(%{usage: %{input_tokens: 0, output_tokens: 0}, turns: 0})
    end
  end

  test "fanout_hint and parent_step_id reach the router request" do
    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]},
      %{id: "c", target: :t, input: 3, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:ok, _} = Runner.run(steps, run_opts(run: {__MODULE__, :echo, []}))
    assert_receive {:router_request, "b", req}
    assert req.fanout_hint == 2 and req.parent_step_id == "a"
    assert req.path == ["workflow:wf-t", "workflow_step:b"]
  end

  test "a step with several dependencies sends its first as parent_step_id" do
    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: []},
      %{id: "c", target: :t, input: 3, descriptor: %{}, depends_on: ["b", "a"]}
    ]

    assert {:ok, _} = Runner.run(steps, run_opts(run: {__MODULE__, :echo, []}))
    assert_receive {:router_request, "c", req}
    assert req.parent_step_id == "b"
  end

  test "a descriptor's own correlation names do not reach the router beside the runner's" do
    names = ~w(workflow_id step_id parent_step_id fanout_hint path)
    descriptor = Map.new(names, &{&1, "spoof"}) |> Map.put("task_class", "t")
    steps = [%{id: "a", target: :t, input: 1, descriptor: descriptor, depends_on: []}]

    assert {:ok, _} = Runner.run(steps, run_opts(run: {__MODULE__, :echo, []}))
    assert_receive {:router_request, "a", req}
    assert req.workflow_id == "wf-t"
    assert req.path == ["workflow:wf-t", "workflow_step:a"]
    assert req["task_class"] == "t"
    for name <- names, do: refute(Map.has_key?(req, name), "#{name} reached the router")
  end

  test "route: false metadata carries the workflow/workflow_step path frames" do
    steps = [%{id: "t1", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} =
             Runner.run(
               steps,
               run_opts(run: {__MODULE__, :report_opts, [Registered.self_name()]})
             )

    assert_receive {:ran, opts}
    assert opts[:metadata][:path] == ["workflow:wf-t", "workflow_step:t1"]
  end

  test "the step telemetry span carries the workflow/workflow_step path frames" do
    owner = self()

    # The handler is global and other async modules emit the same event.
    handler = fn
      _event, _measurements, %{workflow_id: "wf-t"} = meta, _config ->
        send(owner, {:telemetry_meta, meta})

      _event, _measurements, _meta, _config ->
        :ok
    end

    :telemetry.attach(
      "topology-path-test",
      [:mimir_orchestration, :step, :stop],
      handler,
      nil
    )

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} = Runner.run(steps, run_opts(run: {__MODULE__, :echo, []}))
    assert_receive {:telemetry_meta, meta}
    assert meta.path == ["workflow:wf-t", "workflow_step:a"]
  after
    :telemetry.detach("topology-path-test")
  end

  test "a no_candidate verdict is a routing failure, never a nil-grant dispatch" do
    defmodule NoCandidateRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts),
        do: Mimir.RouteResponse.new(%{"verdict" => "no_candidate", "decision_id" => "d1"})
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, :no_candidate}}} =
             Runner.run(steps, router: {NoCandidateRouter, []}, run: {__MODULE__, :never, []})
  end

  test "an {:ok, _} that is not a RouteResponse is a routing failure" do
    defmodule MapRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts), do: {:ok, %{"placement" => %{"model" => "m"}}}
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, {:invalid_route_response, %{}}}}} =
             Runner.run(steps, router: {MapRouter, []}, run: {__MODULE__, :never, []})
  end

  test "a placement with no grant is a routing failure, never a dispatch" do
    defmodule NoGrantRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts),
        do: Mimir.RouteResponse.new(%{"verdict" => "placement", "placement" => %{"model" => "m"}})
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, :no_grant}}} =
             Runner.run(steps, router: {NoGrantRouter, []}, run: {__MODULE__, :never, []})
  end

  test "a router's own error is a routing failure carrying that error" do
    defmodule DownRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts), do: {:error, {:http_error, 503, "down"}}
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, {:http_error, 503, "down"}}}} =
             Runner.run(steps, router: {DownRouter, []}, run: {__MODULE__, :never, []})
  end

  test "a routed step with no router is a routing failure" do
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, :no_router}}} =
             Runner.run(steps, run: {__MODULE__, :never, []})
  end

  test ":step_timeout is honored, and :infinity is the long-session escape hatch" do
    run = {__MODULE__, :sleep, [200]}
    steps = [%{id: "slow", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_crashed, "slow", :timeout}} =
             Runner.run(steps, run_opts(run: run, step_timeout: 50))

    # Long agent sessions can disable the timeout.
    assert {:ok, %{results: %{"slow" => :late}}} =
             Runner.run(steps, run_opts(run: run, step_timeout: :infinity))
  end

  test "a step that exits is a step_crashed error, not an exit of the caller" do
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:error, {:step_crashed, "a", {:exit, :boom}}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :exit_boom, []}))
  end

  test "a step that returns neither {:ok, _} nor {:error, _} is a tagged error" do
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:error, {:step_failed, "a", {:bad_return, :done}}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :bad_return, []}))
  end

  test "a step's input sees its dependencies' results only" do
    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false},
      %{id: "x", target: :t, input: 2, descriptor: %{}, depends_on: [], route: false},
      %{
        id: "b",
        target: :t,
        descriptor: %{},
        depends_on: ["a"],
        route: false,
        input: %StepInput{template: "{{x}}"}
      }
    ]

    assert {:error, {:step_failed, "b", {:unresolved_ref, "x"}}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :echo, []}))
  end

  test "max_concurrency caps how many steps of a wave run at once, and that many do overlap" do
    assert %{peak: 1} = run_wave_with_cap(1)
    assert %{peak: 2} = run_wave_with_cap(2)
  end

  # Each step announces itself and holds until released, so the peak is read while
  # the wave is parked at its cap, with no dependence on timing or scheduler count.
  defp run_wave_with_cap(cap) do
    counter = :"runner_test_counter_#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.start_link(fn -> %{running: 0, peak: 0} end, name: counter)

    opts =
      run_opts(run: {__MODULE__, :gated, [Registered.self_name(), counter]}, max_concurrency: cap)

    steps =
      for id <- ["a", "b", "c"],
          do: %{id: id, target: :t, input: id, descriptor: %{}, depends_on: [], route: false}

    run = Task.async(fn -> Runner.run(steps, opts) end)

    parked =
      for _ <- 1..cap do
        assert_receive {:started, pid}, 1_000
        pid
      end

    refute_receive {:started, _}, 50
    state = Agent.get(counter, & &1)

    Enum.each(parked, &send(&1, :go))

    for _ <- 1..(length(steps) - cap) do
      assert_receive {:started, pid}, 1_000
      send(pid, :go)
    end

    assert {:ok, _} = Task.await(run)
    state
  end

  test "a failing step lets its running siblings finish before the run halts" do
    owner = self()
    handler = fn _event, _measurements, meta, _config -> send(owner, {:stopped, meta.step_id}) end
    :telemetry.attach("wave-drain", [:mimir_orchestration, :step, :stop], handler, nil)

    steps = [
      %{id: "f", target: :t, input: :fail, descriptor: %{}, depends_on: [], route: false},
      %{
        id: "s",
        target: :t,
        input: {:sleep, 100, :late},
        descriptor: %{},
        depends_on: [],
        route: false
      },
      %{
        id: "s2",
        target: :t,
        input: {:sleep, 250, :later},
        descriptor: %{},
        depends_on: [],
        route: false
      },
      %{id: "n", target: :t, input: 1, descriptor: %{}, depends_on: ["s"], route: false}
    ]

    assert {:error, {:step_failed, "f", :kaput}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :drain, []}))

    assert_received {:stopped, "s"}
    assert_received {:stopped, "s2"}
    refute_received {:stopped, "n"}
  after
    :telemetry.detach("wave-drain")
  end

  test "halt: :immediate stops a failing step's running siblings" do
    owner = self()
    handler = fn _event, _measurements, meta, _config -> send(owner, {:stopped, meta.step_id}) end
    :telemetry.attach("halt-immediate", [:mimir_orchestration, :step, :stop], handler, nil)

    steps = [
      %{id: "f", target: :t, input: :fail, descriptor: %{}, depends_on: [], route: false},
      %{
        id: "s",
        target: :t,
        input: {:sleep, 1_000, :late},
        descriptor: %{},
        depends_on: [],
        route: false
      }
    ]

    assert {:error, {:step_failed, "f", :kaput}} =
             Runner.run(steps, run_opts(run: {__MODULE__, :drain, []}, halt: :immediate))

    assert_received {:stopped, "f"}
    refute_received {:stopped, "s"}
  after
    :telemetry.detach("halt-immediate")
  end
end
