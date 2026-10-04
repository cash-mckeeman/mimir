defmodule MimirWorkflows.DagTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Dag

  defp step(id, deps), do: %{id: id, depends_on: deps}

  test "diamond groups into minimal phases with co-phased middle" do
    steps = [step("a", []), step("b", ["a"]), step("c", ["a"]), step("d", ["b", "c"])]
    assert {:ok, [["a"], middle, ["d"]]} = Dag.waves(steps)
    assert Enum.sort(middle) == ["b", "c"]
  end

  test "independent steps share phase zero" do
    assert {:ok, [phase]} = Dag.waves([step(:x, []), step(:y, [])])
    assert Enum.sort(phase) == [:x, :y]
  end

  test "cycle is an error, not a hang" do
    assert {:error, :cyclic} = Dag.waves([step("a", ["b"]), step("b", ["a"])])
  end

  test "unknown dependency is a distinct error" do
    assert {:error, {:unknown_dependency, "ghost"}} = Dag.waves([step("a", ["ghost"])])
  end

  test "empty list yields no phases" do
    assert {:ok, []} = Dag.waves([])
  end

  test "infer_edges is input_from union prev-in-order" do
    items = [
      %{id: "extract", input_from: []},
      %{id: "identify", input_from: []},
      %{id: "finalize", input_from: ["extract"]}
    ]

    assert Enum.sort(Dag.infer_edges(items)) ==
             Enum.sort([
               {"extract", "identify"},
               {"identify", "finalize"},
               {"extract", "finalize"}
             ])
  end
end
