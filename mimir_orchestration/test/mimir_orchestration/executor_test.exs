defmodule MimirOrchestration.ExecutorTest do
  @moduledoc """
  What crosses the executor seam is plain data. The guard refuses each banned kind at
  any depth, names where it is, and runs no executor. A second executor, written
  against the seam alone, runs a payload that has been through the external term
  format, and gets the in-memory executor's results.
  """
  use ExUnit.Case, async: true

  alias MimirOrchestration.{Compiler, Exec, NodeResult, Policy, Runner, StepCall}

  defmodule NeverExecutor do
    @behaviour MimirOrchestration.Executor
    @impl true
    def execute(_payload) do
      send(self(), :executed)
      {:ok, %{results: %{}, workflow_id: "never"}}
    end
  end

  defmodule Run do
    def ok(%StepCall{input: input}, _data), do: {:ok, input}
  end

  defmodule PlacementRouter do
    @behaviour Mimir.RouterClient
    @impl true
    def route(req, opts) do
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "placement" => %{"model" => opts[:model]},
        "grant" => %{"key" => "k-" <> req.step_id},
        "decision_id" => "d-#{req.step_id}-#{req.fanout_hint}"
      })
    end
  end

  # Reports what routing gave the step: the granted model and key, the decision
  # id (which carries the fan-out hint), and the turn guard's verdict on a fresh turn.
  defmodule RoutedRunner do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run(_ref, input, opts) do
      %{"model" => model, "key" => key} = opts[:model]
      verdict = opts[:turn_guard].(%{usage: %{}, turns: 0})
      text = Enum.join([model, key, opts[:metadata][:decision_id], verdict, input], " ")
      {:ok, %NodeResult{text: text, raw: %{}}}
    end
  end

  defp steps,
    do: [%{id: "a", target: :t, input: 1, descriptor: %{}, depends_on: [], route: false}]

  defp refused(opts, steps \\ steps()) do
    result = Runner.run(steps, Keyword.merge([executor: NeverExecutor, workflow_id: "wf"], opts))
    refute_received :executed
    result
  end

  for {kind, term} <- [
        function: quote(do: fn -> :ok end),
        pid: quote(do: self()),
        reference: quote(do: make_ref()),
        port: quote(do: hd(Port.list()))
      ] do
    test "a #{kind} nested in the :run MFA's extra_args is refused by path" do
      assert {:error, {:not_serialisable, [:run, :extra_args, 0, :owner], unquote(kind)}} =
               refused(run: {Run, :ok, [%{owner: unquote(term)}]})
    end
  end

  test "a pid in the router's options is refused by path" do
    assert {:error, {:not_serialisable, [:router, :opts, 0, 1, :to], :pid}} =
             refused(
               run: {Run, :ok, [[]]},
               router: {Mimir.RouterClient.HTTP, [capture: %{to: self()}]}
             )
  end

  test "a pid in the params is refused by path" do
    assert {:error, {:not_serialisable, [:params, "owner"], :pid}} =
             refused(run: {Run, :ok, [[]]}, params: %{"owner" => self()})
  end

  test "a pid as the workflow id is refused by path" do
    assert {:error, {:not_serialisable, [:workflow_id], :pid}} =
             refused(run: {Run, :ok, [[]]}, workflow_id: self())
  end

  test "a function as max_concurrency is refused by path" do
    assert {:error, {:not_serialisable, [:max_concurrency], :function}} =
             refused(run: {Run, :ok, [[]]}, max_concurrency: fn -> 4 end)
  end

  test "a pid inside a struct is refused" do
    assert {:error, {:not_serialisable, [:run, :extra_args, 0, :host], :pid}} =
             refused(run: {Run, :ok, [%URI{host: self()}]})
  end

  test "a container under a map value is walked" do
    assert {:error, {:not_serialisable, [:run, :extra_args, 0, :owner, 0], :pid}} =
             refused(run: {Run, :ok, [%{owner: [self()]}]})
  end

  test "the tail of an improper list is walked" do
    assert {:error, {:not_serialisable, [:run, :extra_args, 0, 1], :pid}} =
             refused(run: {Run, :ok, [[1 | self()]]})
  end

  test "a banned map key is reported at the path of the map that holds it" do
    assert {:error, {:not_serialisable, [:run, :extra_args, 0], :pid}} =
             refused(run: {Run, :ok, [%{self() => :owner}]})
  end

  test "a closure as a step's input is refused" do
    steps = [
      %{id: "a", target: :t, input: fn _ -> 1 end, descriptor: %{}, depends_on: [], route: false}
    ]

    assert {:error, {:not_serialisable, [:steps, 0, :input], :function}} =
             refused([run: {Run, :ok, [[]]}], steps)
  end

  test "a closure as :run is refused" do
    assert {:error, {:not_serialisable, [:run], :function}} = refused(run: fn _ -> :ok end)
  end

  for run <- [quote(do: {Run, :ok}), quote(do: {Run, :ok, %{}})] do
    test "#{Macro.to_string(run)} as :run is not a callable" do
      assert refused(run: unquote(run)) == {:error, {:not_a_callable, unquote(run)}}
    end
  end

  test "Exec.run/3 hands the payload to the :executor it is given" do
    assert {:ok, %{results: %{}, workflow_id: "never"}} =
             Exec.run(plan(), %{"q" => "hi"}, executor: NeverExecutor)

    assert_received :executed
  end

  test "a second executor, given the payload as external terms, gets the in-memory results" do
    run = fn executor ->
      Exec.run(plan(), %{"q" => "hi"},
        workflow_id: "wf-rt",
        executor: executor,
        router: {PlacementRouter, [model: "fleet-rt"]},
        agent_runner: RoutedRunner
      )
    end

    assert {:ok, %{results: %{"a" => "hi", "b" => "hi", "c" => c, "d" => d}}} =
             in_memory = run.(MimirOrchestration.Executor.InMemory)

    assert c.text == "fleet-rt k-c d-c-2 cont hi"
    assert d.text == "fleet-rt k-d d-d-2 cont hi"

    assert run.(MimirOrchestration.Test.SequentialExecutor) == in_memory
  end

  defp plan do
    spec = %{
      "name" => "plan",
      "version" => 1,
      "params" => ["q"],
      "steps" => [
        %{
          "id" => "a",
          "kind" => "tool",
          "tool" => "echo",
          "input" => "{{params.q}}",
          "depends_on" => []
        },
        %{
          "id" => "b",
          "kind" => "tool",
          "tool" => "echo",
          "input" => "{{a}}",
          "depends_on" => ["a"]
        },
        %{
          "id" => "c",
          "kind" => "agent",
          "agent" => "routed",
          "input" => "{{b}}",
          "depends_on" => ["b"],
          "descriptor" => %{"task_class" => "analysis", "budget_ceiling_microdollars" => 1}
        },
        %{
          "id" => "d",
          "kind" => "agent",
          "agent" => "routed",
          "input" => "{{b}}",
          "depends_on" => ["b"],
          "descriptor" => %{"task_class" => "analysis", "budget_ceiling_microdollars" => 1}
        }
      ]
    }

    policy = %Policy{
      agent_registry: %{"routed" => :routed},
      allowed_tools: %{"echo" => {__MODULE__, :echo, []}},
      budget_ceiling_microdollars: 10
    }

    {:ok, compiled} = Compiler.compile(spec, policy)

    compiled
  end

  def echo(input), do: {:ok, input}
end
