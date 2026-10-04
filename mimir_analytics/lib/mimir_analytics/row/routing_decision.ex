defmodule MimirAnalytics.Row.RoutingDecision do
  @moduledoc """
  One row of `routing_decisions` — a gateway `"routing_decision"` line.
  `new/1` owns flattening the nested `descriptor`/`verdict`/`snapshot`
  (and `descriptor.agent`) wire shape onto the table's flat columns —
  formerly positional `d`/`v`/`s`/`agent` digs at the mapper call site.
  """

  @enforce_keys [:decision_id, :source_file]
  defstruct [
    :decision_id,
    :workflow_id,
    :step_id,
    :grant_id,
    :task_class,
    :budget_ceiling_microdollars,
    :latency_tolerance_ms,
    :runtime_preference,
    :agent_digest,
    :outcome,
    :chosen_model,
    :chosen_lane,
    :reasons,
    :candidates,
    :snapshot_at,
    :degraded_lanes,
    :ts,
    :source_file
  ]

  @type t :: %__MODULE__{
          # "rd_..."
          decision_id: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          grant_id: String.t() | nil,
          task_class: String.t() | nil,
          budget_ceiling_microdollars: integer() | nil,
          latency_tolerance_ms: integer() | nil,
          runtime_preference: String.t() | nil,
          agent_digest: String.t() | nil,
          # placement | no_candidate
          outcome: String.t() | nil,
          chosen_model: String.t() | nil,
          chosen_lane: String.t() | nil,
          reasons: list(),
          candidates: list(),
          snapshot_at: String.t() | nil,
          degraded_lanes: list(),
          ts: String.t() | nil,
          source_file: String.t()
        }

  @doc ~s[Build a `t()` from a decoded "routing_decision" line plus "source_file".]
  @spec new(map()) :: t()
  def new(l) do
    d = l["descriptor"] || %{}
    v = l["verdict"] || %{}
    s = l["snapshot"] || %{}
    agent = d["agent"] || %{}

    %__MODULE__{
      decision_id: Map.fetch!(l, "decision_id"),
      workflow_id: l["workflow_id"],
      step_id: l["step_id"],
      grant_id: l["grant_id"],
      task_class: d["task_class"],
      budget_ceiling_microdollars: d["budget_ceiling_microdollars"],
      latency_tolerance_ms: d["latency_tolerance_ms"],
      runtime_preference: d["runtime_preference"],
      agent_digest: agent["digest"],
      outcome: v["outcome"],
      chosen_model: v["model"],
      chosen_lane: v["lane"],
      reasons: v["reasons"] || [],
      candidates: v["candidates"] || [],
      snapshot_at: s["snapshot_at"],
      degraded_lanes: s["degraded_lanes"] || [],
      ts: l["ts"],
      source_file: Map.fetch!(l, "source_file")
    }
  end
end
