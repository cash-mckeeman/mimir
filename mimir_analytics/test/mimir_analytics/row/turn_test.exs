defmodule MimirAnalytics.Row.TurnTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.Turn

  test "new/1 builds a t() from a source map" do
    row =
      Turn.new(%{
        "run_id" => "r1",
        "turn" => 1,
        "terminal" => "end_turn",
        "input_tokens" => 100,
        "output_tokens" => 50,
        "source_file" => "f.jsonl"
      })

    assert %Turn{run_id: "r1", turn: 1, terminal: "end_turn"} = row
  end

  test "enforce_keys raises when run_id, turn, or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(Turn, terminal: "x") end
  end
end
