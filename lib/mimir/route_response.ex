defmodule Mimir.RouteResponse do
  @moduledoc """
  The parsed result of a routing call (`Mimir.RouterClient.route/2`). This is
  the single boundary where an atom- or string-keyed decoded JSON response is
  turned into mimir's struct vocabulary: build with `new/1`, then consume
  assertively (`resp.grant.budget_microdollars`, pattern-match on `verdict`).
  Downstream code never touches a raw route map.

  `new/1` unifies the wire's two locations for `reasons`/`candidates` — nested
  inside `placement` on a placement verdict, top-level on a `no_candidate`
  verdict — onto the top-level `reasons`/`candidates` fields, so consumers see
  one shape regardless of verdict.
  """
  alias Mimir.{Candidate, Grant, Placement}

  @enforce_keys [:verdict]
  defstruct [
    :verdict,
    :placement,
    :grant,
    :workflow_id,
    :step_id,
    :decision_id,
    :snapshot_at,
    candidates: [],
    reasons: []
  ]

  @type t :: %__MODULE__{
          verdict: :placement | :no_candidate,
          placement: Placement.t() | nil,
          grant: Grant.t() | nil,
          candidates: [Candidate.t()],
          reasons: [String.t()],
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          decision_id: String.t() | nil,
          snapshot_at: String.t() | nil
        }

  @doc """
  Parse a decoded route response (atom- or string-keyed) into a
  `%RouteResponse{}`. Returns `{:error, {:invalid_route_response, reason}}` on a
  shape it cannot parse (unknown verdict, placement verdict with no model,
  non-map input).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(resp) when is_map(resp) do
    with {:ok, verdict} <- parse_verdict(fetch(resp, :verdict)),
         placement_map = fetch(resp, :placement) || %{},
         {:ok, placement} <- parse_placement(verdict, fetch(resp, :placement)) do
      {:ok,
       %__MODULE__{
         verdict: verdict,
         placement: placement,
         grant: parse_grant(fetch(resp, :grant)),
         candidates:
           parse_candidates(fetch(resp, :candidates) || fetch(placement_map, :candidates)),
         reasons: fetch(resp, :reasons) || fetch(placement_map, :reasons) || [],
         workflow_id: fetch(resp, :workflow_id),
         step_id: fetch(resp, :step_id),
         decision_id: fetch(resp, :decision_id),
         snapshot_at: fetch(resp, :snapshot_at)
       }}
    end
  end

  def new(_not_a_map), do: {:error, {:invalid_route_response, :not_a_map}}

  defp parse_verdict(v) when v in ["placement", :placement], do: {:ok, :placement}
  defp parse_verdict(v) when v in ["no_candidate", :no_candidate], do: {:ok, :no_candidate}
  defp parse_verdict(other), do: {:error, {:invalid_route_response, {:verdict, other}}}

  defp parse_placement(:no_candidate, _), do: {:ok, nil}

  defp parse_placement(:placement, p) when is_map(p) do
    case fetch(p, :model) do
      nil -> {:error, {:invalid_route_response, :placement_missing_model}}
      model -> {:ok, %Placement{lane: fetch(p, :lane), model: model, runtime: fetch(p, :runtime)}}
    end
  end

  defp parse_placement(:placement, _),
    do: {:error, {:invalid_route_response, :placement_missing_model}}

  defp parse_grant(g) when is_map(g) do
    case fetch(g, :key) do
      nil ->
        nil

      key ->
        %Grant{
          key: key,
          expires_at: fetch(g, :expires_at),
          budget_microdollars: fetch(g, :budget_microdollars)
        }
    end
  end

  defp parse_grant(_), do: nil

  defp parse_candidates(list) when is_list(list) do
    list |> Enum.map(&parse_candidate/1) |> Enum.reject(&is_nil/1)
  end

  defp parse_candidates(_), do: []

  defp parse_candidate(c) when is_map(c) do
    case fetch(c, :id) do
      nil ->
        nil

      id ->
        %Candidate{
          id: id,
          verdict: parse_candidate_verdict(fetch(c, :verdict), fetch(c, :reason))
        }
    end
  end

  defp parse_candidate(_), do: nil

  defp parse_candidate_verdict(v, _) when v in ["chosen", :chosen], do: :chosen
  defp parse_candidate_verdict(v, _) when v in ["ranked", :ranked], do: :ranked

  defp parse_candidate_verdict(v, reason) when v in ["excluded", :excluded],
    do: {:excluded, reason}

  defp parse_candidate_verdict({:excluded, reason}, _), do: {:excluded, reason}
  defp parse_candidate_verdict(other, _), do: other

  # The ONE dual-key reader in the codebase. Map.get (never bracket access) so a
  # struct passed in would not raise; reads atom- and string-keyed maps alike.
  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_, _), do: nil
end
