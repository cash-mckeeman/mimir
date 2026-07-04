defmodule Mimir.Oracle do
  @moduledoc """
  The pure routing decision: filter-then-rank over catalog entries. Every input
  entry receives a verdict (`:chosen | :ranked | {:excluded, reason}`) — the
  verdict table IS the decision record's body. No Repo, no process state, no
  side effects; the operational world arrives as a `Snapshot` argument.

  Rank (v1, deliberately weightless): cheapest projected step cost, tie-break
  ascending p50 latency, then ascending priority. When eval scorecards exist,
  `quality_bar` becomes a fourth FILTER (below-bar excluded), not a weight.
  """
  alias Mimir.{Catalog.Entry, Descriptor, Snapshot}

  defmodule Policy do
    @moduledoc "Routing constraints layered on top of the catalog itself."
    defstruct allowed_models: []
    @type t :: %__MODULE__{allowed_models: [String.t()]}
  end

  defmodule Placement do
    @moduledoc "A chosen entry, why it was chosen, and every candidate's verdict."
    @enforce_keys [:entry, :reasons, :candidates]
    defstruct [:entry, :reasons, :candidates]

    @type t :: %__MODULE__{
            entry: Mimir.Catalog.Entry.t(),
            reasons: [String.t()],
            candidates: [map()]
          }
  end

  @spec decide(Descriptor.t(), [Entry.t()], Policy.t(), Snapshot.t()) ::
          {:placement, Placement.t()} | {:no_candidate, [term()], [map()]}
  def decide(%Descriptor{} = d, entries, %Policy{} = policy, %Snapshot{} = snap) do
    judged = Enum.map(entries, fn e -> {e, judge(e, d, policy, snap)} end)

    case Enum.split_with(judged, fn {_e, verdict} -> verdict == :viable end) do
      {[], _} ->
        {:no_candidate, no_candidate_reasons(judged), verdict_table(judged, nil)}

      {viable, _} ->
        ranked = Enum.sort_by(viable, fn {e, _} -> rank_key(e, d, snap) end)
        {chosen, _} = hd(ranked)

        {:placement,
         %Placement{
           entry: chosen,
           reasons: placement_reasons(chosen, d),
           candidates: verdict_table(judged, chosen.id)
         }}
    end
  end

  # ── judgment: first failing filter wins the exclusion reason ────────────

  defp judge(e, d, policy, snap) do
    with :ok <- check_capabilities(e, d),
         :ok <- check_policy(e, policy),
         :ok <- check_runtime(e, d),
         :ok <- check_health(e, snap),
         :ok <- check_latency(e, d),
         :ok <- check_cost(e, d, snap) do
      :viable
    end
  end

  defp check_capabilities(e, d) do
    case d.capabilities -- e.capabilities do
      [] -> :ok
      missing -> {:excluded, {:capability, missing}}
    end
  end

  defp check_policy(_e, %Policy{allowed_models: []}), do: :ok

  defp check_policy(e, %Policy{allowed_models: allowed}) do
    if e.model in allowed, do: :ok, else: {:excluded, {:policy, :model_not_allowed}}
  end

  defp check_runtime(_e, %Descriptor{runtime_preference: :any}), do: :ok

  defp check_runtime(e, %Descriptor{runtime_preference: pref}) do
    if e.runtime == pref, do: :ok, else: {:excluded, {:runtime, pref}}
  end

  defp check_health(e, snap) do
    case Map.get(snap.health, e.lane, :ok) do
      :ok -> :ok
      state -> {:excluded, {:health, state}}
    end
  end

  defp check_latency(%Entry{p50_latency_ms: nil}, _d), do: :ok

  defp check_latency(e, d) do
    if e.p50_latency_ms <= d.latency_tolerance_ms,
      do: :ok,
      else: {:excluded, {:latency, e.p50_latency_ms}}
  end

  defp check_cost(_e, %Descriptor{expected_tokens: nil}, _snap), do: :ok

  defp check_cost(e, d, snap) do
    cost = projected_cost(e, d, snap)
    cap = min_cap(d.budget_ceiling_microdollars, snap.parent_remaining)

    if cost <= cap, do: :ok, else: {:excluded, {:cost, %{projected: cost, cap: cap}}}
  end

  defp min_cap(ceiling, :unlimited), do: ceiling
  defp min_cap(ceiling, remaining), do: min(ceiling, remaining)

  defp projected_cost(e, %Descriptor{expected_tokens: %{in: i, out: o}}, snap) do
    %{input: in_rate, output: out_rate} = Map.get(snap.pricing, e.model, %{input: 0, output: 0})
    div(i * in_rate, 1_000_000) + div(o * out_rate, 1_000_000)
  end

  # ── ranking ──────────────────────────────────────────────────────────────

  defp rank_key(e, %Descriptor{expected_tokens: nil}, snap) do
    # No projection: rank on per-token input price as the cost proxy.
    %{input: in_rate} = Map.get(snap.pricing, e.model, %{input: 0, output: 0})
    {in_rate, e.p50_latency_ms || 999_999_999, e.priority}
  end

  defp rank_key(e, d, snap),
    do: {projected_cost(e, d, snap), e.p50_latency_ms || 999_999_999, e.priority}

  defp placement_reasons(_chosen, %Descriptor{expected_tokens: nil}),
    do: ["capability_match", "cheapest_by_rate"]

  defp placement_reasons(_chosen, _d), do: ["capability_match", "cheapest_viable"]

  defp verdict_table(judged, chosen_id) do
    Enum.map(judged, fn
      {e, :viable} when e.id == chosen_id -> %{id: e.id, verdict: :chosen}
      {e, :viable} -> %{id: e.id, verdict: :ranked}
      {e, {:excluded, _} = ex} -> %{id: e.id, verdict: ex}
    end)
  end

  defp no_candidate_reasons(judged) do
    judged
    |> Enum.map(fn {_e, {:excluded, reason}} -> exclusion_class(reason) end)
    |> Enum.uniq()
  end

  defp exclusion_class({class, _detail}), do: class
end
