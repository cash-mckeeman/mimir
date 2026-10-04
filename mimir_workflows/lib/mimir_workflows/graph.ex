defmodule MimirWorkflows.Graph do
  @moduledoc """
  Pure directed-graph algorithms over an edge list of `{upstream,
  downstream}` pairs.

  Nodes may be any term. Adjacency, reachability and cycle detection use
  exact map/set identity, so `1` and `1.0` are distinct nodes.
  `strictly_upstream?/3` first excludes nodes equal under `==`, including
  numerically equal integers and floats, then checks exact reachability.
  """

  @type node_id :: term()
  @type edge :: {node_id(), node_id()}
  @type adjacency :: %{node_id() => [node_id()]}

  @doc """
  Forward adjacency map (`upstream => [downstream]`) built from an edge
  list. Downstreams accumulate in reverse insertion order, which no
  consumer depends on.
  """
  @spec adjacency([edge()]) :: adjacency()
  def adjacency(edges) do
    Enum.reduce(edges, %{}, fn {up, down}, acc ->
      Map.update(acc, up, [down], &[down | &1])
    end)
  end

  @doc """
  Every node reachable from `start` following forward edges, **including
  `start` itself**.
  """
  @spec reachable_from(node_id(), [edge()]) :: MapSet.t()
  def reachable_from(start, edges) do
    collect(start, adjacency(edges), MapSet.new([start]))
  end

  @doc """
  True if there is a directed path `target → … → node` with `target !=
  node`.
  """
  @spec strictly_upstream?(node_id(), node_id(), [edge()]) :: boolean()
  def strictly_upstream?(target, node, _edges) when target == node, do: false

  def strictly_upstream?(target, node, edges) do
    MapSet.member?(reachable_from(target, edges), node)
  end

  @doc """
  True if the edge list contains a directed cycle.

  Standard DFS: `visiting` is the current DFS stack (a back-edge into it
  is a cycle); `visited` is nodes whose subtrees have been fully explored
  and proven cycle-free. Threading `visited` across DFS roots keeps the
  walk linear in node + edge count instead of exponential on DAGs with
  shared descendants.
  """
  @spec has_cycle?([edge()]) :: boolean()
  def has_cycle?(edges) do
    nodes =
      edges
      |> Enum.flat_map(fn {a, b} -> [a, b] end)
      |> Enum.uniq()

    graph = adjacency(edges)

    # Keep DFS sets opaque across the recursive calls.
    result = Enum.reduce_while(nodes, {:ok, :sets.new(version: 2)}, &visit_root(&1, graph, &2))

    result == :cycle
  end

  # ---------------------------------------------------------------------------

  defp visit_root(node, graph, {:ok, visited}) do
    if :sets.is_element(node, visited) do
      {:cont, {:ok, visited}}
    else
      case visit(node, graph, :sets.new(version: 2), visited) do
        :cycle -> {:halt, :cycle}
        {:ok, visited} -> {:cont, {:ok, visited}}
      end
    end
  end

  defp collect(node, graph, acc) do
    graph
    |> Map.get(node, [])
    |> Enum.reduce(acc, fn neighbor, set ->
      if MapSet.member?(set, neighbor) do
        set
      else
        collect(neighbor, graph, MapSet.put(set, neighbor))
      end
    end)
  end

  defp visit(node, graph, visiting, visited) do
    cond do
      :sets.is_element(node, visiting) ->
        :cycle

      :sets.is_element(node, visited) ->
        {:ok, visited}

      true ->
        visiting = :sets.add_element(node, visiting)
        neighbours = Map.get(graph, node, [])

        case visit_neighbours(neighbours, graph, visiting, visited) do
          :cycle -> :cycle
          {:ok, vis} -> {:ok, :sets.add_element(node, vis)}
        end
    end
  end

  defp visit_neighbours(neighbours, graph, visiting, visited) do
    Enum.reduce_while(neighbours, {:ok, visited}, fn n, {:ok, vis} ->
      case visit(n, graph, visiting, vis) do
        :cycle -> {:halt, :cycle}
        {:ok, vis} -> {:cont, {:ok, vis}}
      end
    end)
  end
end
