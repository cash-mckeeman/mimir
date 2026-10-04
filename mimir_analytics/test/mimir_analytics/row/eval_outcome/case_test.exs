defmodule MimirAnalytics.Row.EvalOutcome.CaseTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.EvalOutcome.Case

  test "new/2 joins a results case with its matching judge entry" do
    c = %{
      "case_id" => "case_01_synthetic",
      "passed" => true,
      "reason" => nil,
      "elapsed_ms" => 41_000,
      "session_id" => "sess_01aaaa"
    }

    judge = %{
      "case_id" => "case_01_synthetic",
      "passed" => true,
      "reasoning" => "ok",
      "elapsed_ms" => 4000
    }

    row = Case.new(c, judge)

    assert %Case{
             case_id: "case_01_synthetic",
             passed: true,
             session_id: "sess_01aaaa",
             judge_passed: true,
             judge_reasoning: "ok",
             judge_elapsed_ms: 4000
           } = row
  end

  test "new/2 tolerates an absent judge (mechanical mode has none)" do
    c = %{"case_id" => "case_08", "passed" => false, "session_id" => "sess_01bbbb"}
    row = Case.new(c, %{})

    assert row.judge_passed == nil
    assert row.judge_reasoning == nil
    assert row.judge_elapsed_ms == nil
  end

  test "enforce_keys raises without case_id" do
    assert_raise ArgumentError, fn -> struct!(Case, passed: true) end
  end
end
