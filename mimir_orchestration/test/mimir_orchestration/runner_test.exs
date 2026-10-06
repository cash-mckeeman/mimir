defmodule MimirOrchestration.RunnerTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Runner

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
      Keyword.merge([router: {FakeRouter, [capture: capture_name()]}, workflow_id: "wf-t"], extra)

  # The router captures to the calling process's registered name, not its pid, so
  # router opts stay plain data.
  defp capture_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _unregistered ->
        name = :"runner_test_#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end

  test "waves execute in dependency order; results keyed by id" do
    run_fun = fn _t, input, _o -> {:ok, {:did, input}} end

    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:ok, %{results: %{"a" => {:did, 1}, "b" => {:did, 2}}, workflow_id: "wf-t"}} =
             Runner.run(steps, run_opts(run_fun: run_fun))
  end

  test "arity-1 input is resolved with completed results at dispatch" do
    owner = self()

    run_fun = fn _t, input, opts ->
      send(owner, {:input, opts[:metadata][:step_id], input})
      {:ok, "r-" <> opts[:metadata][:step_id]}
    end

    steps = [
      %{id: "a", target: :t, input: "static", descriptor: %{}, depends_on: []},
      %{
        id: "b",
        target: :t,
        descriptor: %{},
        depends_on: ["a"],
        input: fn upstream -> {:got, upstream["a"]} end
      }
    ]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_receive {:input, "a", "static"}
    assert_receive {:input, "b", {:got, "r-a"}}
  end

  test "route: false skips the router and passes correlation metadata only" do
    owner = self()

    run_fun = fn _t, _i, opts ->
      send(owner, {:ran, opts})
      {:ok, :done}
    end

    steps = [%{id: "t1", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_receive {:ran, opts}
    assert opts[:metadata][:step_id] == "t1"
    refute Keyword.has_key?(opts, :model)
    refute_receive {:router_request, "t1", _}, 50
  end

  test "step failure halts remaining waves" do
    run_fun = fn
      _t, :boom, _o -> {:error, :kaput}
      _t, i, _o -> {:ok, i}
    end

    steps = [
      %{id: "a", target: :t, input: :boom, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:error, {:step_failed, "a", :kaput}} = Runner.run(steps, run_opts(run_fun: run_fun))
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
      owner = self()

      run_fun = fn _t, _i, opts ->
        send(owner, {:opts, opts})
        {:ok, :done}
      end

      steps = [
        %{id: "a", target: :t, input: 1, descriptor: %{"task_class" => "t"}, depends_on: []}
      ]

      assert {:ok, _} =
               Runner.run(steps, router: {TypedRouter, []}, run_fun: run_fun, workflow_id: "wf")

      assert_receive {:opts, opts}
      assert is_function(opts[:turn_guard], 1)
      assert opts[:metadata][:decision_id] == "dec-a"
      assert opts[:metadata][:mimir_request_id] == "dec-a"
      assert :cont == opts[:turn_guard].(%{usage: %{input_tokens: 0, output_tokens: 0}, turns: 0})
    end

    defmodule PricedRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(req, _opts) do
        Mimir.RouteResponse.new(%{
          "verdict" => "placement",
          "decision_id" => "dec-#{req.step_id}",
          "placement" => %{
            "model" => "anthropic:claude-haiku-4-5",
            "lane" => "bedrock",
            "runtime" => "local"
          },
          "grant" => %{"key" => "sk-grant", "budget_microdollars" => 1_000}
        })
      end
    end

    test "the turn guard halts once spend passes the grant's budget" do
      owner = self()

      run_fun = fn _t, _i, opts ->
        send(owner, {:opts, opts})
        {:ok, :done}
      end

      steps = [
        %{id: "a", target: :t, input: 1, descriptor: %{"task_class" => "t"}, depends_on: []}
      ]

      assert {:ok, _} =
               Runner.run(steps, router: {PricedRouter, []}, run_fun: run_fun, workflow_id: "wf")

      assert_receive {:opts, opts}

      assert {:halt, {:budget_exceeded, %{budget_microdollars: 1_000}}} =
               opts[:turn_guard].(%{
                 usage: %{input_tokens: 10_000_000, output_tokens: 10_000_000},
                 turns: 1
               })
    end
  end

  test "fanout_hint and parent_step_id reach the router request" do
    run_fun = fn _t, i, _o -> {:ok, i} end

    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []},
      %{id: "b", target: :t, input: 2, descriptor: %{}, depends_on: ["a"]},
      %{id: "c", target: :t, input: 3, descriptor: %{}, depends_on: ["a"]}
    ]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_receive {:router_request, "b", req}
    assert req.fanout_hint == 2 and req.parent_step_id == "a"
    assert req.path == ["workflow:wf-t", "workflow_step:b"]
  end

  test "a descriptor's own correlation names do not reach the router beside the runner's" do
    run_fun = fn _t, i, _o -> {:ok, i} end

    descriptor = %{"task_class" => "t", "workflow_id" => "spoof", "path" => ["spoof"]}
    steps = [%{id: "a", target: :t, input: 1, descriptor: descriptor, depends_on: []}]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_receive {:router_request, "a", req}
    assert req.workflow_id == "wf-t"
    assert req.path == ["workflow:wf-t", "workflow_step:a"]
    assert req["task_class"] == "t"
    refute Map.has_key?(req, "workflow_id")
    refute Map.has_key?(req, "path")
  end

  test "route: false metadata carries the workflow/workflow_step path frames" do
    owner = self()

    run_fun = fn _t, _i, opts ->
      send(owner, {:ran, opts})
      {:ok, :done}
    end

    steps = [%{id: "t1", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
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

    run_fun = fn _t, i, _o -> {:ok, i} end
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
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

    run_fun = fn _t, _i, _o -> flunk("run_fun must not be called on no_candidate") end
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, :no_candidate}}} =
             Runner.run(steps, router: {NoCandidateRouter, []}, run_fun: run_fun)
  end

  test "a router that returns anything but a RouteResponse is a routing failure" do
    defmodule MapRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts), do: {:ok, %{"placement" => %{"model" => "m"}}}
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
    run_fun = fn _t, _i, _o -> flunk("must not dispatch") end

    assert {:error, {:step_failed, "a", {:routing_failed, {:invalid_route_response, %{}}}}} =
             Runner.run(steps, router: {MapRouter, []}, run_fun: run_fun)
  end

  test "a placement with no grant is a routing failure, never a dispatch" do
    defmodule NoGrantRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts),
        do: Mimir.RouteResponse.new(%{"verdict" => "placement", "placement" => %{"model" => "m"}})
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
    run_fun = fn _t, _i, _o -> flunk("must not dispatch") end

    assert {:error, {:step_failed, "a", {:routing_failed, :no_grant}}} =
             Runner.run(steps, router: {NoGrantRouter, []}, run_fun: run_fun)
  end

  test "a router's own error is a routing failure carrying that error" do
    defmodule DownRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(_req, _opts), do: {:error, {:http_error, 503, "down"}}
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
    run_fun = fn _t, _i, _o -> flunk("must not dispatch") end

    assert {:error, {:step_failed, "a", {:routing_failed, {:http_error, 503, "down"}}}} =
             Runner.run(steps, router: {DownRouter, []}, run_fun: run_fun)
  end

  test "a routed step with no router is a routing failure" do
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
    run_fun = fn _t, _i, _o -> flunk("must not dispatch") end

    assert {:error, {:step_failed, "a", {:routing_failed, :no_router}}} =
             Runner.run(steps, run_fun: run_fun)
  end

  test ":step_timeout is honored, and :infinity is the long-session escape hatch" do
    run_fun = fn _t, _i, _o ->
      Process.sleep(200)
      {:ok, :late}
    end

    steps = [%{id: "slow", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_crashed, "slow", :timeout}} =
             Runner.run(steps, run_opts(run_fun: run_fun, step_timeout: 50))

    # Long agent sessions can disable the timeout.
    assert {:ok, %{results: %{"slow" => :late}}} =
             Runner.run(steps, run_opts(run_fun: run_fun, step_timeout: :infinity))
  end

  test "a step that exits is a step_crashed error, not an exit of the caller" do
    run_fun = fn _t, _i, _o -> exit(:boom) end
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:error, {:step_crashed, "a", {:exit, :boom}}} =
             Runner.run(steps, run_opts(run_fun: run_fun))
  end

  test "a step that returns neither {:ok, _} nor {:error, _} is a tagged error" do
    run_fun = fn _t, _i, _o -> :done end
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

    assert {:error, {:step_failed, "a", {:bad_return, :done}}} =
             Runner.run(steps, run_opts(run_fun: run_fun))
  end

  test "a step's input sees its dependencies' results only" do
    owner = self()

    run_fun = fn _t, input, _o ->
      send(owner, {:input, input})
      {:ok, :r}
    end

    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false},
      %{id: "x", target: :t, input: 2, descriptor: %{}, depends_on: [], route: false},
      %{
        id: "b",
        target: :t,
        descriptor: %{},
        depends_on: ["a"],
        route: false,
        input: fn upstream -> {Map.keys(upstream), upstream["x"]} end
      }
    ]

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_receive {:input, {["a"], nil}}
  end

  test "max_concurrency caps how many steps of a wave run at once, and that many do overlap" do
    assert %{peak: 1} = run_wave_with_cap(1)
    assert %{peak: 2} = run_wave_with_cap(2)
  end

  # Each step announces itself and holds until released, so the peak is read while
  # the wave is parked at its cap, with no dependence on timing or scheduler count.
  defp run_wave_with_cap(cap) do
    owner = self()
    {:ok, counter} = Agent.start_link(fn -> %{running: 0, peak: 0} end)

    run_fun = fn _t, input, _o ->
      Agent.update(counter, fn %{running: r, peak: p} ->
        %{running: r + 1, peak: max(p, r + 1)}
      end)

      send(owner, {:started, self()})
      receive do: (:go -> :ok)
      Agent.update(counter, fn %{running: r} = state -> %{state | running: r - 1} end)
      {:ok, input}
    end

    steps =
      for id <- ["a", "b", "c"],
          do: %{id: id, target: :t, input: id, descriptor: %{}, depends_on: [], route: false}

    run =
      Task.async(fn -> Runner.run(steps, run_opts(run_fun: run_fun, max_concurrency: cap)) end)

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

    run_fun = fn
      _t, :fail, _o -> {:error, :kaput}
      _t, :slow, _o -> Process.sleep(100) && {:ok, :late}
      _t, :slower, _o -> Process.sleep(250) && {:ok, :later}
      _t, input, _o -> {:ok, input}
    end

    steps = [
      %{id: "f", target: :t, input: :fail, descriptor: %{}, depends_on: [], route: false},
      %{id: "s", target: :t, input: :slow, descriptor: %{}, depends_on: [], route: false},
      %{id: "s2", target: :t, input: :slower, descriptor: %{}, depends_on: [], route: false},
      %{id: "n", target: :t, input: 1, descriptor: %{}, depends_on: ["s"], route: false}
    ]

    assert {:error, {:step_failed, "f", :kaput}} = Runner.run(steps, run_opts(run_fun: run_fun))
    assert_received {:stopped, "s"}
    assert_received {:stopped, "s2"}
    refute_received {:stopped, "n"}
  after
    :telemetry.detach("wave-drain")
  end
end
