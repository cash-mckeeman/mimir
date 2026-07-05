defmodule Mimir.DecisionRecordTest do
  @moduledoc """
  Unit tests for DecisionRecord.build/5 — pure map shape.
  """
  use ExUnit.Case, async: true

  alias Mimir.{Catalog.Entry, DecisionRecord, Descriptor, Snapshot, TurnEvents}
  alias Mimir.Oracle.Placement

  setup do
    case start_supervised(TurnEvents) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

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

  defp placement do
    %Placement{
      entry: %Entry{
        id: "haiku-managed",
        model: "anthropic:claude-haiku-4-5",
        model_spec: %{},
        lane: :anthropic,
        runtime: :managed
      },
      reasons: ["capability_match", "cheapest_viable"],
      candidates: [
        %{id: "haiku-managed", verdict: :chosen},
        %{id: "nemotron", verdict: :ranked},
        %{id: "gpt4", verdict: {:excluded, {:capability, [:vision]}}}
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
      rpm_headroom: :unlimited,
      snapshot_at: ~U[2026-07-04 00:00:00Z]
    }
  end

  # ── DecisionRecord shape tests ────────────────────────────────────────────

  describe "build/5 shape" do
    test "returns a binary-keyed map with all top-level keys" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert is_map(record)

      for key <- ~w(decision_id workflow_id step_id grant_id descriptor snapshot verdict) do
        assert Map.has_key?(record, key), "missing key: #{key}"
      end
    end

    test "decision_id has 'rd_' prefix and is 29 chars (3 + 26)" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert String.starts_with?(record["decision_id"], "rd_")
      assert String.length(record["decision_id"]) == 29
      suffix = String.slice(record["decision_id"], 3..-1//1)
      assert String.match?(suffix, ~r/^[a-z2-7]{26}$/)
    end

    test "carries workflow_id and step_id from ids arg" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-99", step_id: "step-z"},
          snapshot()
        )

      assert record["workflow_id"] == "wf-99"
      assert record["step_id"] == "step-z"
    end

    test "grant_id echoes the given grant id string" do
      grant_id = "3f2f1c9a-0000-4000-8000-000000000001"

      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          grant_id,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert record["grant_id"] == grant_id
    end

    test "grant_id is nil when no grant" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      assert is_nil(record["grant_id"])
    end

    test "descriptor echo contains descriptor fields, not pricing" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      d = record["descriptor"]
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

      record =
        Mimir.DecisionRecord.build(
          d,
          {:no_candidate, [], []},
          nil,
          %{workflow_id: "w", step_id: "s"},
          snapshot
        )

      assert record["descriptor"]["agent"] ==
               %{"digest" => "sha256:abc", "name" => "business_analyst", "version" => "3"}

      assert record["descriptor"]["max_outcome_iterations"] == 4
    end

    test "snapshot summary has snapshot_at and degraded_lanes only — no pricing" do
      degraded_snap = snapshot(%{"anthropic" => :degraded, "bedrock" => :degraded})

      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          degraded_snap
        )

      snap = record["snapshot"]
      assert Map.has_key?(snap, "snapshot_at")
      assert Map.has_key?(snap, "degraded_lanes")
      refute Map.has_key?(snap, "pricing")
      assert snap["degraded_lanes"] == ["anthropic", "bedrock"]
    end

    test "no full pricing table anywhere in the record" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      inspected = inspect(record)
      refute String.contains?(inspected, "\"pricing\"")
      refute String.contains?(inspected, "input: 250_000")
      refute String.contains?(inspected, "250000")
    end

    test "placement verdict encodes model, lane, reasons, and full candidate table" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      v = record["verdict"]
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
           %{id: "haiku-managed", verdict: {:excluded, {:capability, [:tools]}}},
           %{id: "nemotron", verdict: {:excluded, {:cost, %{projected: 9_999, cap: 1_000}}}}
         ]}

      record =
        DecisionRecord.build(
          descriptor(),
          nc_verdict,
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      v = record["verdict"]
      assert v["outcome"] == "no_candidate"
      assert "capability" in v["reasons"]
      assert "cost" in v["reasons"]
      assert length(v["candidates"]) == 2
    end

    test "TurnEvents.append/3 accepts the built record (no-op but no raise)" do
      record =
        DecisionRecord.build(
          descriptor(),
          {:placement, placement()},
          nil,
          %{workflow_id: "wf-1", step_id: "step-a"},
          snapshot()
        )

      rid = "rd_test_#{System.unique_integer([:positive])}"
      assert :ok = TurnEvents.append(rid, "routing_decision", record)
      assert [%{"type" => "routing_decision", "gen_ai" => ^record}] = TurnEvents.take(rid)
    end
  end
end
