defmodule Mimir.DecisionRecord do
  @moduledoc """
  Typed routing-decision record. `build/5` returns a `%DecisionRecord{}`;
  `to_event/1` renders the binary-keyed audit map suitable for appending as a
  turn event. No Repo, no clock beyond accepting the snapshot's `snapshot_at`.

  ## Key conventions
  - `to_event/1` map keys are strings (binary), never atoms.
  - Grant id is the caller-supplied grant key's UUID string. The plaintext
    bearer token is NEVER included.
  - Snapshot summary: only `snapshot_at` + a list of degraded lanes — the full
    pricing table is NOT copied in (it can be large and is not decision-relevant
    at audit time; the embedder has the full table if needed).
  - `decision_id`: `"rd_"` prefix + 26-char lowercase base32 of 16 random bytes.
  """

  alias Mimir.{Descriptor, Oracle.Placement, Snapshot}

  @enforce_keys [:decision_id, :descriptor, :snapshot, :verdict]
  defstruct [:decision_id, :workflow_id, :step_id, :grant_id, :descriptor, :snapshot, :verdict]

  @type verdict :: {:placement, Placement.t()} | {:no_candidate, [term()], [map()]}
  @type t :: %__MODULE__{
          decision_id: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          grant_id: String.t() | nil,
          descriptor: Descriptor.t(),
          snapshot: Snapshot.t(),
          verdict: verdict()
        }

  @doc """
  Build a `%DecisionRecord{}` carrying the source data for a routing decision.

  Arguments:
  - `descriptor` — the `%Descriptor{}` the oracle was called with.
  - `verdict` — `{:placement, %Placement{}}` or `{:no_candidate, reasons, candidates}`.
  - `grant_id` — the minted grant key's UUID string (never the plaintext bearer token), or nil.
  - `ids` — `%{workflow_id: string, step_id: string}` (the correlation ids).
  - `snapshot` — the `%Snapshot{}` used for the decision.

  Render with `to_event/1` to get the binary-keyed map ready to append as a
  `routing_decision` turn event.
  """
  @spec build(
          Descriptor.t(),
          verdict(),
          String.t() | nil,
          %{workflow_id: String.t() | nil, step_id: String.t() | nil},
          Snapshot.t()
        ) :: t()
  def build(%Descriptor{} = descriptor, verdict, grant_or_nil, ids, %Snapshot{} = snapshot) do
    %__MODULE__{
      decision_id: gen_decision_id(),
      workflow_id: ids[:workflow_id],
      step_id: ids[:step_id],
      grant_id: grant_id(grant_or_nil),
      descriptor: descriptor,
      snapshot: snapshot,
      verdict: verdict
    }
  end

  @doc """
  Render a `%DecisionRecord{}` as the binary-keyed audit map ready to append
  as a `routing_decision` turn event.
  """
  @spec to_event(t()) :: map()
  def to_event(%__MODULE__{} = rec) do
    %{
      "decision_id" => rec.decision_id,
      "workflow_id" => rec.workflow_id,
      "step_id" => rec.step_id,
      "grant_id" => rec.grant_id,
      "descriptor" => descriptor_echo(rec.descriptor),
      "snapshot" => snapshot_summary(rec.snapshot),
      "verdict" => encode_verdict(rec.verdict)
    }
  end

  # ── private helpers ──────────────────────────────────────────────────────

  defp gen_decision_id do
    # 16 random bytes → 26-char lowercase base32 (no padding): "rd_" + 26 chars.
    "rd_" <> Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)
  end

  defp grant_id(nil), do: nil
  defp grant_id(id) when is_binary(id), do: id

  defp descriptor_echo(%Descriptor{} = d) do
    %{
      "task_class" => d.task_class,
      "budget_ceiling_microdollars" => d.budget_ceiling_microdollars,
      "latency_tolerance_ms" => d.latency_tolerance_ms,
      "capabilities" => Enum.map(d.capabilities, &to_string/1),
      "runtime_preference" => to_string(d.runtime_preference),
      "agent" => agent_echo(d.agent),
      "max_outcome_iterations" => d.max_outcome_iterations
    }
  end

  defp agent_echo(nil), do: nil

  defp agent_echo(%{digest: digest} = a),
    do: %{"digest" => digest, "name" => a[:name], "version" => a[:version]}

  defp snapshot_summary(%Snapshot{snapshot_at: at, health: health}) do
    degraded =
      health
      |> Enum.filter(fn {_lane, state} -> state != :ok end)
      |> Enum.map(fn {lane, _state} -> to_string(lane) end)
      |> Enum.sort()

    %{
      "snapshot_at" => DateTime.to_iso8601(at),
      "degraded_lanes" => degraded
    }
  end

  defp encode_verdict({:placement, %Placement{} = p}) do
    %{
      "outcome" => "placement",
      "model" => p.entry.model,
      "lane" => to_string(p.entry.lane),
      "reasons" => p.reasons,
      "candidates" => encode_candidates(p.candidates)
    }
  end

  defp encode_verdict({:no_candidate, reasons, candidates}) do
    %{
      "outcome" => "no_candidate",
      "reasons" => Enum.map(reasons, &to_string/1),
      "candidates" => encode_candidates(candidates)
    }
  end

  defp encode_candidates(candidates) when is_list(candidates) do
    Enum.map(candidates, fn
      %{id: id, verdict: :chosen} ->
        %{"id" => id, "verdict" => "chosen"}

      %{id: id, verdict: :ranked} ->
        %{"id" => id, "verdict" => "ranked"}

      %{id: id, verdict: {:excluded, reason}} ->
        %{"id" => id, "verdict" => "excluded", "reason" => inspect(reason)}
    end)
  end

  defp encode_candidates(_), do: []
end
