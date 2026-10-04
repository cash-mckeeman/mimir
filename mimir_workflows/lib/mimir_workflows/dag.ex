defmodule MimirWorkflows.Dag do
  @moduledoc """
  Step-spec-level DAG operations: minimal-phase grouping for execution
  (`waves/1`) and opt-in dependency inference (`infer_edges/1`).

  `waves/1` operates on any maps carrying `:id` and `:depends_on`; ids are
  opaque terms compared by value — never converted. Guards run before
  Kahn's algorithm because Kahn alone would silently drop cycle members
  and treat an unknown dependency as forever-unsatisfied.

  `dep_spec`/`input_spec` are a **host-seam contract, not a runtime-validated
  one**: `waves/1` and `infer_edges/1` check *values* they can reason about
  (unknown `depends_on` ids, cycles) but assume every element already has
  the required keys — a map missing `:id` or `:depends_on`/`:input_from`
  raises (`KeyError`) rather than returning a diagnostic. Callers that
  build these maps from a schema-validated `%MimirWorkflows.Spec{}` (as
  `MimirWorkflows.Compiler` does) get the shape for free; hand-built specs
  are the caller's responsibility.
  """

  alias MimirWorkflows.Graph

  @typedoc "Opaque step identifier; compared by value only, never atomized."
  @type step_id :: term()

  @typedoc "Shape expected by `waves/1` — see the moduledoc's host-seam-contract note."
  @type dep_spec :: %{required(:id) => step_id(), required(:depends_on) => [step_id()]}

  @typedoc "Shape expected by `infer_edges/1` — see the moduledoc's host-seam-contract note."
  @type input_spec :: %{required(:id) => step_id(), required(:input_from) => [step_id()]}

  @doc """
  Groups steps into minimal execution phases (fewest phases, most in-phase
  parallelism). Each step lands in phase `max(dep phases) + 1` (`0` when it
  has no dependencies).

  Returns `{:error, {:unknown_dependency, id}}` if any `depends_on` id is
  not a step in the list, and `{:error, :cyclic}` for dependency cycles.
  """
  @spec waves([dep_spec()]) ::
          {:ok, [[step_id()]]} | {:error, :cyclic} | {:error, {:unknown_dependency, step_id()}}
  def waves([]), do: {:ok, []}

  def waves(steps) do
    ids = MapSet.new(steps, & &1.id)

    with :ok <- check_deps_known(steps, ids),
         edges = for(s <- steps, d <- s.depends_on, do: {d, s.id}),
         false <- Graph.has_cycle?(edges) do
      {:ok, topo_phases(steps)}
    else
      true -> {:error, :cyclic}
      {:error, _} = error -> error
    end
  end

  @doc """
  Opt-in edge inference: `input_from` ∪ prev-in-order. Declaring a linear
  workflow needs zero edges (each item implicitly depends on its
  predecessor); only divergences are declared via `input_from`. Returns
  deduplicated `{upstream, downstream}` pairs suitable for `Graph`.
  """
  @spec infer_edges([input_spec()]) :: [Graph.edge()]
  def infer_edges(items) do
    {_prev, edges} =
      Enum.reduce(items, {nil, []}, fn item, {prev, edges} ->
        prev_edge = if prev, do: [{prev, item.id}], else: []
        input_edges = for src <- item.input_from, do: {src, item.id}
        {item.id, edges ++ prev_edge ++ input_edges}
      end)

    Enum.uniq(edges)
  end

  # ---------------------------------------------------------------------------

  defp check_deps_known(steps, ids) do
    steps
    |> Enum.flat_map(& &1.depends_on)
    |> Enum.find(&(not MapSet.member?(ids, &1)))
    |> case do
      nil -> :ok
      unknown -> {:error, {:unknown_dependency, unknown}}
    end
  end

  defp topo_phases(steps) do
    step_index = Map.new(steps, fn s -> {s.id, s} end)

    steps
    |> kahn_sort()
    |> Enum.reduce(%{}, fn step_id, phase_of ->
      step = Map.fetch!(step_index, step_id)

      phase =
        case step.depends_on do
          [] -> 0
          deps -> deps |> Enum.map(&Map.fetch!(phase_of, &1)) |> Enum.max() |> Kernel.+(1)
        end

      Map.put(phase_of, step_id, phase)
    end)
    |> Enum.group_by(fn {_id, phase} -> phase end, fn {id, _phase} -> id end)
    |> Enum.sort_by(fn {phase, _ids} -> phase end)
    |> Enum.map(fn {_phase, ids} -> ids end)
  end

  defp kahn_sort(steps) do
    in_degree = Map.new(steps, fn s -> {s.id, length(s.depends_on)} end)

    adj =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(step.depends_on, acc, fn dep_id, a ->
          Map.update(a, dep_id, [step.id], &[step.id | &1])
        end)
      end)

    queue =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    kahn_loop(queue, in_degree, adj, [])
  end

  defp kahn_loop([], _in_degree, _adj, sorted), do: Enum.reverse(sorted)

  defp kahn_loop([id | rest], in_degree, adj, sorted) do
    dependents = Map.get(adj, id, [])

    {new_in_degree, newly_free} =
      Enum.reduce(dependents, {in_degree, []}, fn dep_id, {deg_acc, free_acc} ->
        new_deg = Map.fetch!(deg_acc, dep_id) - 1
        updated = Map.put(deg_acc, dep_id, new_deg)
        if new_deg == 0, do: {updated, [dep_id | free_acc]}, else: {updated, free_acc}
      end)

    kahn_loop(rest ++ newly_free, new_in_degree, adj, [id | sorted])
  end
end
