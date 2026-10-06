defmodule MimirOrchestration.RunnerTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Runner

  defmodule FakeRouter do
    @behaviour MimirOrchestration.RouterClient
    @impl true
    def route(req, opts) do
      if pid = opts[:capture], do: send(pid, {:router_request, req.step_id, req})

      {:ok,
       %{
         "placement" => %{"model" => "fleet-fast", "lane" => "test"},
         "grant" => %{"key" => "sk-test", "budget_microdollars" => 100_000},
         "decision_id" => "decision-#{req.step_id}"
       }}
    end
  end

  defp run_opts(extra),
    do: Keyword.merge([router: {FakeRouter, [capture: self()]}, workflow_id: "wf-t"], extra)

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

  describe "typed decisions (mimir 0.3.0)" do
    defmodule TypedRouter do
      @behaviour MimirOrchestration.RouterClient
      @impl true
      def route(req, _opts) do
        {:ok,
         %{
           "verdict" => "placement",
           "decision_id" => "dec-#{req.step_id}",
           "placement" => %{"model" => "fleet-fast", "lane" => "bedrock", "runtime" => "local"},
           "grant" => %{
             "key" => "sk-grant",
             "budget_microdollars" => 5_000,
             "expires_at" => "2026-07-09T00:00:00Z"
           }
         }}
      end
    end

    test "typed decision threads turn_guard + decision_id metadata" do
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

    test "raw/legacy decisions still take the raw path" do
      owner = self()

      run_fun = fn _t, _i, opts ->
        send(owner, {:opts, opts})
        {:ok, :done}
      end

      steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
      assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun))

      assert_receive {:opts, opts}
      refute Keyword.has_key?(opts, :turn_guard)
      assert opts[:metadata][:mimir_request_id] == "decision-a"
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

    handler = fn _event, _measurements, meta, _config -> send(owner, {:telemetry_meta, meta}) end

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

  test "raw-path placement base_url threads into the model map when present" do
    defmodule BaseUrlRouter do
      @behaviour MimirOrchestration.RouterClient
      @impl true
      def route(_req, _opts) do
        {:ok,
         %{
           "placement" => %{"model" => "m1", "base_url" => "https://mimir.test"},
           "grant" => %{"key" => "sk-x"},
           "decision_id" => "d1"
         }}
      end
    end

    owner = self()

    run_fun = fn _t, _i, opts ->
      send(owner, {:model, opts[:model]})
      {:ok, :done}
    end

    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]
    assert {:ok, _} = Runner.run(steps, router: {BaseUrlRouter, []}, run_fun: run_fun)

    assert_receive {:model, model}
    assert model == %{"key" => "sk-x", "model" => "m1", "base_url" => "https://mimir.test"}
  end

  test "a no_candidate verdict is a routing failure, never a nil-grant dispatch" do
    defmodule NoCandidateRouter do
      @behaviour MimirOrchestration.RouterClient
      @impl true
      def route(_req, _opts), do: {:ok, %{"verdict" => "no_candidate", "decision_id" => "d1"}}
    end

    run_fun = fn _t, _i, _o -> flunk("run_fun must not be called on no_candidate") end
    steps = [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: []}]

    assert {:error, {:step_failed, "a", {:routing_failed, :no_candidate}}} =
             Runner.run(steps, router: {NoCandidateRouter, []}, run_fun: run_fun)
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

  test "max_concurrency caps how many steps of a wave run at once" do
    {:ok, counter} = Agent.start_link(fn -> %{running: 0, peak: 0} end)

    run_fun = fn _t, input, _o ->
      Agent.update(counter, fn %{running: r, peak: p} ->
        %{running: r + 1, peak: max(p, r + 1)}
      end)

      Process.sleep(30)
      Agent.update(counter, fn %{running: r} = state -> %{state | running: r - 1} end)
      {:ok, input}
    end

    steps =
      for id <- ["a", "b", "c"],
          do: %{id: id, target: :t, input: id, descriptor: %{}, depends_on: [], route: false}

    assert {:ok, _} = Runner.run(steps, run_opts(run_fun: run_fun, max_concurrency: 1))
    assert %{peak: 1} = Agent.get(counter, & &1)
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
