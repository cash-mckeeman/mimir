defmodule MimirOrchestration.AgentRunner.RMARunOutcomeTest do
  use ExUnit.Case, async: true
  @moduletag :rma

  if Code.ensure_loaded?(ReqManagedAgents.SessionResult) do
    alias MimirOrchestration.AgentRunner.RMA.RunOutcome
    alias ReqManagedAgents.SessionResult

    test "synchronous success selects its result without adding the notification" do
      result = %SessionResult{text: "sync", usage: %ReqManagedAgents.Usage{input_tokens: 12}}

      notified = %SessionResult{
        text: "different",
        usage: %ReqManagedAgents.Usage{input_tokens: 99}
      }

      assert {:ok, outcome} = RunOutcome.new({:ok, result}, notified)
      assert outcome.return == {:ok, result}
      assert outcome.session_result == result
      assert outcome.authority == :session_result
    end

    test "an error selects its supplied partial result or unknown" do
      partial = %SessionResult{text: "partial"}
      assert {:ok, outcome} = RunOutcome.new({:error, :failure}, partial)
      assert outcome.return == {:error, :failure}
      assert outcome.session_result == partial
      assert outcome.authority == :partial_result
      assert {:ok, unknown} = RunOutcome.new({:error, :failure}, nil)
      assert unknown.session_result == nil
      assert unknown.authority == :unknown
    end

    test "invalid return and notification shapes name their field" do
      for value <- [:ok, nil, {:ok, %{}}, {:other, :value}] do
        assert {:error, {:invalid_run_outcome, :return}} = RunOutcome.new(value, nil)
      end

      for value <- [%{}, :result, {:ok, %SessionResult{}}] do
        assert {:error, {:invalid_run_outcome, :session_result}} =
                 RunOutcome.new({:error, :failure}, value)
      end
    end
  end
end
