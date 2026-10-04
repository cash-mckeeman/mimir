defmodule MimirWorkflows.GraphTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Graph

  @diamond [{"a", "b"}, {"a", "c"}, {"b", "d"}, {"c", "d"}]

  test "adjacency accumulates downstreams per upstream" do
    adj = Graph.adjacency(@diamond)
    assert Enum.sort(adj["a"]) == ["b", "c"]
    assert adj["b"] == ["d"]
    refute Map.has_key?(adj, "d")
  end

  test "reachable_from includes the start node and all descendants" do
    assert Graph.reachable_from("b", @diamond) == MapSet.new(["b", "d"])
    assert Graph.reachable_from("a", @diamond) == MapSet.new(["a", "b", "c", "d"])
  end

  test "strictly_upstream? is false for self, true along a path" do
    assert Graph.strictly_upstream?("a", "d", @diamond)
    refute Graph.strictly_upstream?("d", "a", @diamond)
    refute Graph.strictly_upstream?("a", "a", @diamond)
  end

  test "cycle detection keeps integer and float nodes distinct" do
    refute Graph.has_cycle?([{1, 1.0}])
    assert Graph.has_cycle?([{1, 1.0}, {1.0, 1}])
  end

  test "has_cycle? detects cycles and clears shared-descendant DAGs" do
    refute Graph.has_cycle?(@diamond)
    assert Graph.has_cycle?([{"a", "b"}, {"b", "c"}, {"c", "a"}])
    assert Graph.has_cycle?([{"x", "x"}])
  end
end
