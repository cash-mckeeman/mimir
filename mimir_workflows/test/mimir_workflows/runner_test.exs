defmodule MimirWorkflows.RunnerTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Runner
  alias MimirWorkflows.TestSteps.{Echo, Fail}

  defp step(id, deps, mod \\ Echo, params \\ %{}),
    do: %{id: id, module: mod, params: params, depends_on: deps}

  test "empty workflow returns empty results" do
    assert {:ok, %{}} = Runner.run([])
  end

  test "sequential steps see direct upstream results" do
    steps = [step("a", [], Echo, %{n: 1}), step("b", ["a"])]
    assert {:ok, results} = Runner.run(steps)
    assert results["b"].upstream == %{"a" => results["a"]}
  end

  test "diamond: sink sees direct deps only, never transitive ancestors" do
    steps = [step(:a, []), step(:b, [:a]), step(:c, [:a]), step(:d, [:b, :c])]
    assert {:ok, results} = Runner.run(steps)
    assert Map.keys(results[:d].upstream) |> Enum.sort() == [:b, :c]
  end

  test "a failing step halts the run with its id" do
    steps = [step("a", []), step("bad", ["a"], Fail), step("never", ["bad"])]
    assert {:error, {:step_failed, "bad", :boom}} = Runner.run(steps)
  end

  test "a cyclic spec is rejected before execution" do
    assert {:error, {:invalid, :cyclic}} = Runner.run([step("a", ["b"]), step("b", ["a"])])
  end
end
