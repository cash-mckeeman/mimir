defmodule Mimir.CloudEvent.TypesTest do
  use ExUnit.Case, async: true

  alias Mimir.CloudEvent.Types
  alias Mimir.Event

  test "for_event/1 builds ai.bizinsights.mimir.<domain>.<type> for each domain" do
    {:ok, llm} = Event.llm(:tool_call, request_id: "r1")
    {:ok, agent} = Event.agent(:terminal, request_id: "r1")
    {:ok, wf} = Event.workflow(:step_stop, request_id: "r1")

    assert Types.for_event(llm) == "ai.bizinsights.mimir.llm.tool_call"
    assert Types.for_event(agent) == "ai.bizinsights.mimir.agent.terminal"
    assert Types.for_event(wf) == "ai.bizinsights.mimir.workflow.step_stop"
  end

  test "record-family helpers are the documented strings" do
    assert Types.routing_decision() == "ai.bizinsights.mimir.routing.decision"
    assert Types.ledger_completion() == "ai.bizinsights.mimir.ledger.completion"
    assert Types.eval_outcome() == "ai.bizinsights.mimir.eval.outcome"
    assert Types.memory(:promoted) == "ai.bizinsights.mimir.memory.promoted"
    assert Types.memory("recalled") == "ai.bizinsights.mimir.memory.recalled"
  end

  test "namespace/0 is the shared prefix" do
    assert Types.namespace() == "ai.bizinsights.mimir"
  end
end
