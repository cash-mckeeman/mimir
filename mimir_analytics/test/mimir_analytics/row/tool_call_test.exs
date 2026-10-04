defmodule MimirAnalytics.Row.ToolCallTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.ToolCall

  test "new/1 extracts id/name/input off the tool-use map" do
    row =
      ToolCall.new(%{
        run_id: "sess_01aaaa",
        turn: nil,
        seq: 1,
        tool_use: %{"id" => "tu_1", "name" => "search_kb", "input" => %{"query" => "q4"}},
        kind: "custom",
        source_file: "f.jsonl"
      })

    assert %ToolCall{
             run_id: "sess_01aaaa",
             seq: 1,
             tool_use_id: "tu_1",
             name: "search_kb",
             kind: "custom",
             input: %{"query" => "q4"},
             source_file: "f.jsonl"
           } = row
  end

  test "new/1 defaults input to %{} when the tool use carries none" do
    row =
      ToolCall.new(%{
        run_id: "r1",
        turn: nil,
        seq: 1,
        tool_use: %{"id" => "tu_1", "name" => "n"},
        kind: "server",
        source_file: "f.jsonl"
      })

    assert row.input == %{}
  end

  test "enforce_keys raises when run_id, seq, or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(ToolCall, name: "x") end
  end
end
