defmodule MimirAnalytics.Row.ModelCallTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.ModelCall

  @line %{
    "kind" => "request_log",
    "request_id" => "req_9f1",
    "virtual_key_id" => "vk_child_1",
    "parent_key_id" => "vk_parent_1",
    "tenant_id" => "tenant-a",
    "lane" => "bedrock_reason",
    "provider" => "bedrock",
    "model_id" => "nemotron-super-3-120b",
    "status" => "success",
    "finish_reason" => "stop",
    "input_tokens" => 4100,
    "output_tokens" => 600,
    "cost_microdollars" => 1834,
    "latency_ms" => 9200,
    "fallback" => false,
    "error_class" => nil,
    "workflow_id" => "wf_demo1",
    "step_id" => "analyze",
    "parent_step_id" => nil,
    "inserted_at" => "2026-07-07T14:01:10Z"
  }

  test "new/1 renames request_id -> mimir_request_id and inserted_at -> ts" do
    row = ModelCall.new(Map.put(@line, "source_file", "gw.jsonl"))

    assert row.mimir_request_id == "req_9f1"
    assert row.ts == "2026-07-07T14:01:10Z"
    assert row.run_id == nil
    assert row.source_file == "gw.jsonl"
  end

  test "new/1 defaults usage/cost to 0 and fallback to false when absent" do
    line =
      @line
      |> Map.drop(["input_tokens", "output_tokens", "cost_microdollars", "fallback"])
      |> Map.put("source_file", "gw.jsonl")

    row = ModelCall.new(line)

    assert row.input_tokens == 0
    assert row.output_tokens == 0
    assert row.cost_microdollars == 0
    assert row.fallback == false
  end

  test "enforce_keys raises when mimir_request_id or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(ModelCall, provider: "x") end
  end
end
