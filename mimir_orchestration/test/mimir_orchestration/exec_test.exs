defmodule MimirOrchestration.ExecTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Compiled, Compiler, Exec, NodeResult, Policy}
  alias MimirOrchestration.Test.Registered

  defmodule Router do
    @behaviour Mimir.RouterClient
    @impl true
    def route(req, _opts) do
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "placement" => %{"model" => "fleet-fast"},
        "grant" => %{"key" => "k"},
        "decision_id" => "d-#{req.step_id}"
      })
    end
  end

  defmodule StubRunner do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run({:rma, name}, input, opts) do
      send(opts[:owner], {:agent_run, name, input, opts[:metadata]})
      send(opts[:owner], {:agent_options, opts})
      {:ok, %NodeResult{text: "out-#{name}", stop_reason: "end_turn", raw: %{}}}
    end
  end

  def upcase(%NodeResult{text: t}), do: {:ok, %{"text" => String.upcase(t)}}

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
      allowed_tools: %{"upcase" => {__MODULE__, :upcase, []}},
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
               agent_runner_opts: [owner: Registered.self_name()]
             )

    assert results["analyze"].text == "out-stub"
    assert results["shout"] == %{"text" => "OUT-STUB"}
    assert_receive {:agent_run, "stub", %{"question" => "kpis"}, %{step_id: "analyze"}}
  end

  test ":step_timeout reaches the runner" do
    defmodule SlowRunner do
      @behaviour MimirOrchestration.AgentRunner
      @impl true
      def run(_ref, _input, _opts) do
        Process.sleep(300)
        {:ok, %NodeResult{text: "late", raw: %{}}}
      end
    end

    assert {:error, {:step_crashed, "analyze", :timeout}} =
             Exec.run(compiled(), %{"q" => "kpis"},
               router: {Router, []},
               agent_runner: SlowRunner,
               step_timeout: 50
             )
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
          target: {__MODULE__, :never_called, []},
          input_template: "{{ghost}}",
          descriptor: %{},
          depends_on: []
        }
      ]
    }

    assert {:error, {:step_failed, "s1", {:unresolved_ref, "ghost"}}} =
             Exec.run(compiled, %{}, router: {Router, []})
  end

  test "an agent runner option that is a closure is refused before any step runs" do
    for key <- [:handler, :provision_fun, :session_fun] do
      assert {:error,
              {:not_serialisable, [:run, :extra_args, 0, :agent_runner_opts, 0, 1], :function}} =
               Exec.run(compiled(), %{"q" => "kpis"},
                 router: {Router, []},
                 agent_runner: StubRunner,
                 agent_runner_opts: [{key, fn -> :ok end}]
               )
    end

    refute_received {:agent_run, _, _, _}
  end

  test "an llm :chat that is a closure is refused before any step runs" do
    assert {:error, {:not_serialisable, [:run, :extra_args, 0, :llm_opts, 0, 1], :function}} =
             Exec.run(compiled(), %{"q" => "kpis"},
               router: {Router, []},
               agent_runner: StubRunner,
               llm_opts: [chat: fn _ -> {:ok, "t"} end]
             )
  end

  test "Exec forwards explicit URLs and preserves binding correlation over extra metadata" do
    assert {:ok, _} =
             Exec.run(compiled(), %{"q" => "test"},
               router: {Router, []},
               workflow_id: "wf-binding",
               data_plane: %{chat_completions: "http://127.0.0.1:8080/v1"},
               agent_runner: StubRunner,
               agent_runner_opts: [
                 owner: Registered.self_name(),
                 metadata: %{workflow_id: "spoof", decision_id: "spoof", custom: "kept"}
               ]
             )

    assert_received {:agent_options, opts}

    assert %Mimir.Binding{data_plane_urls: %{chat_completions: "http://127.0.0.1:8080/v1"}} =
             opts[:binding]

    assert opts[:metadata].workflow_id == "wf-binding"
    assert opts[:metadata].decision_id == "d-analyze"
    assert opts[:metadata].custom == "kept"
    refute_received {:agent_options, _}
  end

  for key <- [:binding, :model, :model_config, :turn_guard, :telemetry_metadata],
      kind <- [:agent, :llm] do
    test "a routed #{kind} refuses the #{key} dispatch override" do
      {plan, option_key, id} =
        if unquote(kind) == :agent do
          {compiled(), :agent_runner_opts, "analyze"}
        else
          {%Compiled{
             name: "model",
             version: 1,
             params: [],
             steps: [
               %{
                 id: "model",
                 kind: "llm",
                 target: nil,
                 runtime: nil,
                 input_template: "q",
                 descriptor: %{},
                 depends_on: []
               }
             ]
           }, :llm_opts, "model"}
        end

      opts =
        [router: {Router, []}, agent_runner: StubRunner]
        |> Keyword.put(option_key, [{unquote(key), "override"}])

      assert {:error, {:step_failed, ^id, {:routed_option_conflict, unquote(key)}}} =
               Exec.run(plan, %{"q" => "test"}, opts)

      refute_received {:agent_run, _, _, _}
    end
  end

  test "unrouted model dispatch retains an explicitly supplied model" do
    config = %{llm_opts: [model: "explicit", chat: {__MODULE__, :model_echo, []}]}
    call = %MimirOrchestration.StepCall{target: :llm, input: "q", opts: [metadata: %{}]}
    assert {:ok, "explicit"} = Exec.dispatch(call, config)
  end

  def model_echo(%{model: model}), do: {:ok, model}
end
