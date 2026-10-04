defmodule MimirAnalytics.Row.EventRawTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.EventRaw

  test "new/1 builds a session-sourced event row" do
    row =
      EventRaw.new(%{
        scope_id: "sess_01aaaa",
        seq: 1,
        ts: nil,
        domain: nil,
        type: "local.model_response",
        payload: %{"type" => "local.model_response", "seq" => 1},
        source: "session",
        source_file: "f.jsonl"
      })

    assert %EventRaw{
             scope_id: "sess_01aaaa",
             seq: 1,
             domain: nil,
             type: "local.model_response",
             source: "session",
             source_file: "f.jsonl"
           } = row
  end

  test "new/1 builds a gateway-sourced event row with a domain" do
    row =
      EventRaw.new(%{
        scope_id: "req_9f1",
        seq: 2,
        ts: nil,
        domain: "llm",
        type: "turn_complete",
        payload: %{"seq" => 2, "type" => "turn_complete"},
        source: "gateway",
        source_file: "f.jsonl"
      })

    assert row.source == "gateway"
    assert row.scope_id == "req_9f1"
    assert row.domain == "llm"
  end

  test "new/1 defaults domain to nil when the key is absent" do
    row =
      EventRaw.new(%{
        scope_id: "req_9f1",
        seq: 3,
        ts: nil,
        type: "reasoning",
        payload: %{},
        source: "gateway",
        source_file: "f.jsonl"
      })

    assert row.domain == nil
  end

  test "new/1 carries the CloudEvents envelope attributes" do
    row =
      EventRaw.new(%{
        scope_id: "req_9f1",
        seq: 2,
        ts: "2026-07-25T14:01:10.123Z",
        domain: "llm",
        type: "tool_call",
        ce_id: "req_9f1:2",
        ce_source: "//gateway.example/prod-1",
        ce_type: "ai.bizinsights.mimir.llm.tool_call",
        payload: %{"specversion" => "1.0"},
        source: "gateway",
        source_file: "f.jsonl"
      })

    assert row.ce_id == "req_9f1:2"
    assert row.ce_source == "//gateway.example/prod-1"
    assert row.ce_type == "ai.bizinsights.mimir.llm.tool_call"
    assert row.ts == "2026-07-25T14:01:10.123Z"
  end

  test "new/1 defaults the envelope attributes to nil when absent" do
    row =
      EventRaw.new(%{
        scope_id: "sess_1",
        seq: 1,
        ts: nil,
        type: "t",
        payload: %{},
        source: "session",
        source_file: "f.jsonl"
      })

    assert {row.ce_id, row.ce_source, row.ce_type} == {nil, nil, nil}
  end

  test "enforce_keys raises when scope_id, seq, or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(EventRaw, type: "x") end
  end
end
