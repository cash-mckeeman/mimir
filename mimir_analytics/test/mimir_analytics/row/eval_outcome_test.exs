defmodule MimirAnalytics.Row.EvalOutcomeTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.EvalOutcome
  alias MimirAnalytics.Row.EvalOutcome.Case

  test "new/1 widens a joined case with report-level context; run_id is the case's session_id" do
    c = Case.new(%{"case_id" => "case_01", "passed" => true, "session_id" => "sess_01aaaa"}, %{})

    row =
      EvalOutcome.new(%{
        case: c,
        agent: "agent_a",
        suite: "suite_a",
        runtime: "local",
        mode: "judge",
        threshold: 0.85,
        pass_rate: 0.8333,
        ts: "2026-07-07T00:00:00Z",
        source_file: "eval_report.json"
      })

    assert %EvalOutcome{
             case_id: "case_01",
             passed: true,
             run_id: "sess_01aaaa",
             agent: "agent_a",
             suite: "suite_a",
             runtime: "local",
             mode: "judge",
             threshold: 0.85,
             pass_rate: 0.8333,
             source_file: "eval_report.json"
           } = row
  end

  test "enforce_keys raises when case_id or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(EvalOutcome, mode: "judge") end
  end
end
