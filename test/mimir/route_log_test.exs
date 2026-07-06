defmodule Mimir.RouteLogTest do
  use ExUnit.Case, async: true

  alias Mimir.{Candidate, Catalog.Entry, DecisionRecord, Descriptor, RouteLog, Snapshot}
  alias Mimir.Oracle.Decision

  defp record do
    {:ok, descriptor} =
      Descriptor.parse(%{
        task_class: "extract",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000
      })

    placement = %Decision{
      entry: %Entry{
        id: "haiku-managed",
        model: "anthropic:claude-haiku-4-5",
        model_spec: %{},
        lane: :anthropic,
        runtime: :managed
      },
      reasons: ["capability_match"],
      candidates: [%Candidate{id: "haiku-managed", verdict: :chosen}]
    }

    snapshot = %Snapshot{
      pricing: %{"anthropic:claude-haiku-4-5" => %{input: 250_000, output: 1_250_000}},
      health: %{},
      parent_remaining: :unlimited,
      rpm_headroom: :unlimited,
      snapshot_at: ~U[2026-07-04 00:00:00Z]
    }

    DecisionRecord.build(
      descriptor,
      {:decision, placement},
      nil,
      %{workflow_id: "wf_1", step_id: "step_1"},
      snapshot
    )
  end

  defp route_log(outcome) do
    %RouteLog{
      request_id: "req_route_abc",
      caller: %{id: "vk-uuid", tenant_id: "t1"},
      correlation: %{workflow_id: "wf_1", step_id: "step_1", parent_step_id: "step_0"},
      outcome: outcome,
      decision_record: record()
    }
  end

  describe "to_meta/2" do
    test "placed and no_candidate are successful verdicts, not errors" do
      for outcome <- [:placed, :no_candidate] do
        meta = RouteLog.to_meta(route_log(outcome), 42)

        assert meta.status == "success"
        assert meta.error_class == nil
        assert meta.error_detail == nil
      end
    end

    test "grant_failed derives status, class, and detail from the one outcome value" do
      meta = RouteLog.to_meta(route_log({:grant_failed, :parent_exhausted}), 42)

      assert meta.status == "error"
      assert meta.error_class == "grant_failed"
      assert meta.error_detail == "parent_exhausted"
    end

    test "threads caller identity and workflow correlation" do
      log = route_log(:placed)
      meta = RouteLog.to_meta(log, 42)

      assert meta.virtual_key_id == log.caller.id
      assert meta.tenant_id == "t1"
      assert meta.lane == "router"
      assert meta.workflow_id == "wf_1"
      assert meta.step_id == "step_1"
      assert meta.parent_step_id == "step_0"
    end

    test "wraps the decision record's rendered event in the TurnEvents envelope" do
      log = route_log(:placed)
      meta = RouteLog.to_meta(log, 42)
      expected_event = DecisionRecord.to_event(log.decision_record)

      assert [
               %{
                 "seq" => 1,
                 "ts" => 42,
                 "type" => "routing_decision",
                 "gen_ai" => ^expected_event
               }
             ] =
               meta.gen_ai_events
    end
  end

  test "gen_request_id/0 mints route-scoped correlation ids" do
    id = RouteLog.gen_request_id()
    assert String.starts_with?(id, "req_route_")
    assert id != RouteLog.gen_request_id()
  end
end
