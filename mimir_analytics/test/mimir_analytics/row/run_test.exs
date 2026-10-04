defmodule MimirAnalytics.Row.RunTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.Run

  test "new/1 maps meta+result onto the flat runs shape" do
    row =
      Run.new(%{
        "meta" => %{
          "capture_key" => "wf_demo1:analyze",
          "workflow_id" => "wf_demo1",
          "step_id" => "analyze",
          "parent_step_id" => nil,
          "tenant_id" => "tenant-a",
          "agent_digest" => "sha256:abc123",
          "agent_name" => "agent_a",
          "agent_version" => "2",
          "runtime" => "local",
          "provider" => "ollama",
          "model" => "nemotron-super-3-120b",
          "lane" => "local_reason",
          "started_at" => "2026-07-07T14:00:00Z",
          "finished_at" => "2026-07-07T14:03:20Z",
          "cost_microdollars" => 0
        },
        "result" => %{
          "outcome" => "ok",
          "terminal" => "end_turn",
          "stop_reason" => "terminal_tool",
          "session_id" => "sess_01aaaa",
          "turns" => 3,
          "usage" => %{"input_tokens" => 8123, "output_tokens" => 1201}
        },
        "source_file" => "session_local.jsonl"
      })

    assert %Run{
             run_id: "sess_01aaaa",
             workflow_id: "wf_demo1",
             step_id: "analyze",
             agent_digest: "sha256:abc123",
             runtime: "local",
             outcome: "ok",
             terminal: "end_turn",
             stop_reason: "terminal_tool",
             turns: 3,
             input_tokens: 8123,
             output_tokens: 1201,
             cost_microdollars: 0,
             source_file: "session_local.jsonl"
           } = row
  end

  test "run_id/2 prefers result.session_id — the analytics-canonical identity — over meta.run_id" do
    assert Run.run_id(%{"run_id" => "legacy"}, %{"session_id" => "authoritative"}) ==
             "authoritative"
  end

  test "run_id/2 falls back to meta.run_id only for legacy files with no session_id" do
    assert Run.run_id(%{"run_id" => "legacy"}, %{}) == "legacy"
    assert Run.run_id(%{"run_id" => "legacy"}, %{"session_id" => nil}) == "legacy"
  end

  test "run_id/2 is nil when neither session_id nor a legacy run_id is present" do
    assert Run.run_id(%{}, %{}) == nil
  end

  test "new/1 prefers result.session_id for run_id even when meta carries a legacy run_id" do
    row =
      Run.new(%{
        "meta" => %{"run_id" => "legacy"},
        "result" => %{"session_id" => "sess_authoritative"},
        "source_file" => "f.jsonl"
      })

    assert row.run_id == "sess_authoritative"
  end

  test "new/1 falls back to meta.run_id for run_id only when result has no session_id" do
    row =
      Run.new(%{
        "meta" => %{"run_id" => "sess_fallback"},
        "result" => %{},
        "source_file" => "f.jsonl"
      })

    assert row.run_id == "sess_fallback"
  end

  test "new/1 defaults missing usage/cost to 0 and stop_reason nil stays nil" do
    row =
      Run.new(%{
        "meta" => %{"run_id" => "r1"},
        "result" => %{},
        "source_file" => "f.jsonl"
      })

    assert row.input_tokens == 0
    assert row.output_tokens == 0
    assert row.cost_microdollars == 0
    assert row.stop_reason == nil
  end

  test "new/1 stringifies a non-binary stop_reason" do
    row =
      Run.new(%{
        "meta" => %{"run_id" => "r1"},
        "result" => %{"stop_reason" => %{"kind" => "weird"}},
        "source_file" => "f.jsonl"
      })

    assert row.stop_reason == inspect(%{"kind" => "weird"})
  end

  test "enforce_keys raises when run_id and source_file aren't both present" do
    assert_raise ArgumentError, fn ->
      struct!(Run, workflow_id: "wf")
    end
  end
end
