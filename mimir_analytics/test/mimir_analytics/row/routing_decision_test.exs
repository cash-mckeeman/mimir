defmodule MimirAnalytics.Row.RoutingDecisionTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.RoutingDecision

  @line %{
    "kind" => "routing_decision",
    "ts" => "2026-07-07T14:01:09Z",
    "decision_id" => "rd_abc",
    "workflow_id" => "wf_demo1",
    "step_id" => "analyze",
    "grant_id" => "vk_child_1",
    "descriptor" => %{
      "task_class" => "reasoning",
      "budget_ceiling_microdollars" => 50_000,
      "latency_tolerance_ms" => 30_000,
      "runtime_preference" => "any",
      "agent" => %{"digest" => "sha256:abc123", "name" => "agent_a", "version" => "2"}
    },
    "snapshot" => %{"snapshot_at" => "2026-07-07T14:01:00Z", "degraded_lanes" => []},
    "verdict" => %{
      "outcome" => "placement",
      "model" => "nemotron-super-3-120b",
      "lane" => "bedrock_reason",
      "reasons" => ["cheapest_passing"],
      "candidates" => [%{"id" => "bedrock_reason/nemotron-super-3-120b", "verdict" => "chosen"}]
    }
  }

  test "new/1 flattens descriptor/verdict/snapshot/agent onto flat columns" do
    row = RoutingDecision.new(Map.put(@line, "source_file", "gw.jsonl"))

    assert row.decision_id == "rd_abc"
    assert row.task_class == "reasoning"
    assert row.budget_ceiling_microdollars == 50_000
    assert row.agent_digest == "sha256:abc123"
    assert row.outcome == "placement"
    assert row.chosen_model == "nemotron-super-3-120b"
    assert row.chosen_lane == "bedrock_reason"
    assert row.reasons == ["cheapest_passing"]
    assert row.snapshot_at == "2026-07-07T14:01:00Z"
    assert row.source_file == "gw.jsonl"
  end

  test "new/1 defaults reasons/candidates/degraded_lanes to [] when the nested maps are absent" do
    line = %{"decision_id" => "rd_x", "source_file" => "gw.jsonl"}
    row = RoutingDecision.new(line)

    assert row.reasons == []
    assert row.candidates == []
    assert row.degraded_lanes == []
    assert row.agent_digest == nil
  end

  test "enforce_keys raises when decision_id or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(RoutingDecision, outcome: "x") end
  end
end
