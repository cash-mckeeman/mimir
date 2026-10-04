defmodule Mimir.DecisionRecordTest do
  @moduledoc """
  Unit tests for DecisionRecord: `build/5` returns a `%DecisionRecord{}`
  carrying the source data; `to_event/1` renders the binary-keyed audit map.
  """
  use ExUnit.Case, async: true

  alias Mimir.{Candidate, Catalog.Entry, DecisionRecord, Descriptor, Snapshot}
  alias Mimir.Oracle.Decision

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp descriptor do
    {:ok, d} =
      Descriptor.parse(%{
        task_class: "extract",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000
      })

    d
  end

  defp decision do
    %Decision{
      entry: %Entry{
        id: "haiku-managed",
        model: "anthropic:claude-haiku-4-5",
        model_spec: %{},
        lane: :anthropic,
        runtime: :managed
      },
      reasons: ["capability_match", "cheapest_viable"],
      candidates: [
        %Candidate{id: "haiku-managed", verdict: :chosen},
        %Candidate{id: "nemotron", verdict: :ranked},
        %Candidate{id: "gpt4", verdict: {:excluded, {:capability, [:vision]}}}
      ]
    }
  end

  defp snapshot(health \\ %{}) do
    %Snapshot{
      pricing: %{
        "anthropic:claude-haiku-4-5" => %{input: 250_000, output: 1_250_000}
      },
      health: health,
      parent_remaining: :unlimited,
      snapshot_at: ~U[2026-07-04 00:00:00Z]
    }
  end

  # ── build/5 struct tests ──────────────────────────────────────────────────

  describe "build/5" do
    test "returns a struct carrying the source data" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          "grant-uuid-1",
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert %DecisionRecord{} = rec
      assert "rd_" <> _ = rec.decision_id
      assert rec.workflow_id == "wf-1"
      assert rec.step_id == "step-a"
      assert rec.grant_id == "grant-uuid-1"
      assert rec.descriptor == descriptor()
      assert rec.snapshot == snapshot()
      assert rec.verdict == {:decision, decision()}
    end

    test "decision_id has 'rd_' prefix and is 29 chars (3 + 26)" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert String.starts_with?(rec.decision_id, "rd_")
      assert String.length(rec.decision_id) == 29
      suffix = String.slice(rec.decision_id, 3..-1//1)
      assert String.match?(suffix, ~r/^[a-z2-7]{26}$/)
    end

    test "grant_id is nil when no grant is given" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert is_nil(rec.grant_id)
    end
  end

  # ── to_event/1 shape tests ────────────────────────────────────────────────

  describe "to_event/1" do
    test "emits the canonical binary-keyed audit map with all top-level keys" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      event = DecisionRecord.to_event(rec)

      assert is_map(event)

      for key <- ~w(decision_id workflow_id step_id grant_id descriptor snapshot verdict) do
        assert Map.has_key?(event, key), "missing key: #{key}"
      end

      assert event["decision_id"] == rec.decision_id
    end

    test "carries workflow_id and step_id from ids arg" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-99", step_id: "step-z"},
          snapshot()
        )

      event = DecisionRecord.to_event(rec)
      assert event["workflow_id"] == "wf-99"
      assert event["step_id"] == "step-z"
    end

    test "grant_id echoes the given grant id string" do
      grant_id = "3f2f1c9a-0000-4000-8000-000000000001"

      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          grant_id,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      event = DecisionRecord.to_event(rec)
      assert event["grant_id"] == grant_id
    end

    test "grant_id is nil when no grant" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      event = DecisionRecord.to_event(rec)
      assert is_nil(event["grant_id"])
    end

    test "descriptor echo contains descriptor fields, not pricing" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      d = DecisionRecord.to_event(rec)["descriptor"]
      assert d["task_class"] == "extract"
      assert d["budget_ceiling_microdollars"] == 50_000
      assert d["latency_tolerance_ms"] == 30_000
    end

    test "descriptor echo carries agent identity and outcome hint" do
      {:ok, d} =
        Mimir.Descriptor.parse(%{
          task_class: "extraction",
          budget_ceiling_microdollars: 10_000,
          latency_tolerance_ms: 5_000,
          agent: %{digest: "sha256:abc", name: "business_analyst", version: "3"},
          max_outcome_iterations: 4
        })

      snapshot = Mimir.Snapshot.assemble([])

      rec =
        DecisionRecord.build(
          d,
          {:no_candidate, [], []},
          nil,
          %{workflow_id: "w", step_id: "s"},
          snapshot
        )

      event = DecisionRecord.to_event(rec)

      assert event["descriptor"]["agent"] ==
               %{"digest" => "sha256:abc", "name" => "business_analyst", "version" => "3"}

      assert event["descriptor"]["max_outcome_iterations"] == 4
    end

    test "snapshot summary has snapshot_at and degraded_lanes only — no pricing" do
      degraded_snap = snapshot(%{"anthropic" => :degraded, "bedrock" => :degraded})

      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          degraded_snap
        )

      snap = DecisionRecord.to_event(rec)["snapshot"]
      assert Map.has_key?(snap, "snapshot_at")
      assert Map.has_key?(snap, "degraded_lanes")
      refute Map.has_key?(snap, "pricing")
      assert snap["degraded_lanes"] == ["anthropic", "bedrock"]
    end

    test "no full pricing table anywhere in the rendered event" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      inspected = inspect(DecisionRecord.to_event(rec))
      refute String.contains?(inspected, "\"pricing\"")
      refute String.contains?(inspected, "input: 250_000")
      refute String.contains?(inspected, "250000")
    end

    test "placement verdict encodes model, lane, reasons, and full candidate table" do
      rec =
        DecisionRecord.build(
          descriptor(),
          {:decision, decision()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      v = DecisionRecord.to_event(rec)["verdict"]
      assert v["outcome"] == "placement"
      assert v["model"] == "anthropic:claude-haiku-4-5"
      assert is_list(v["candidates"])

      by_id = Map.new(v["candidates"], &{&1["id"], &1})
      assert by_id["haiku-managed"]["verdict"] == "chosen"
      assert by_id["nemotron"]["verdict"] == "ranked"
      assert by_id["gpt4"]["verdict"] == "excluded"
      assert by_id["gpt4"]["reason"] =~ "vision"
    end

    test "no_candidate verdict encodes reasons and candidates" do
      nc_verdict =
        {:no_candidate, [:capability, :cost],
         [
           %Candidate{id: "haiku-managed", verdict: {:excluded, {:capability, [:tools]}}},
           %Candidate{
             id: "nemotron",
             verdict: {:excluded, {:cost, %{projected: 9_999, cap: 1_000}}}
           }
         ]}

      rec =
        DecisionRecord.build(
          descriptor(),
          nc_verdict,
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      v = DecisionRecord.to_event(rec)["verdict"]
      assert v["outcome"] == "no_candidate"
      assert "capability" in v["reasons"]
      assert "cost" in v["reasons"]
      assert length(v["candidates"]) == 2
    end
  end
end
