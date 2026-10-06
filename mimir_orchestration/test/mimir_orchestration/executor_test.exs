defmodule MimirOrchestration.ExecutorTest do
  @moduledoc """
  What crosses the executor seam is plain data. The guard refuses each banned kind at
  any depth, names where it is, and runs no executor. A second executor, written
  against the seam alone, runs a payload that has been through the external term
  format, and gets the in-memory executor's results.
  """
  use ExUnit.Case, async: true

  alias MimirOrchestration.{Compiler, Exec, Policy, Runner, StepCall}

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

  test "Exec.run/3 hands the payload to the :executor it is given" do
    assert {:ok, %{results: %{}, workflow_id: "never"}} =
             Exec.run(pair(), %{"q" => "hi"}, executor: NeverExecutor)

    assert_received :executed
  end

  test "a second executor, given the payload as external terms, gets the in-memory results" do
    run = fn executor ->
      Exec.run(pair(), %{"q" => "hi"}, workflow_id: "wf-rt", executor: executor)
    end

    assert {:ok, %{results: %{"a" => "hi", "b" => "hi"}}} =
             in_memory = run.(MimirOrchestration.Executor.InMemory)

    assert run.(MimirOrchestration.Test.SequentialExecutor) == in_memory
  end

  defp pair do
    spec = %{
      "name" => "pair",
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
        }
      ]
    }

    {:ok, compiled} =
      Compiler.compile(spec, %Policy{allowed_tools: %{"echo" => {__MODULE__, :echo, []}}})

    compiled
  end

  def echo(input), do: {:ok, input}
end
