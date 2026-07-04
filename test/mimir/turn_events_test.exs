defmodule Mimir.TurnEventsTest do
  use ExUnit.Case, async: false
  alias Mimir.TurnEvents

  setup do
    case start_supervised(TurnEvents) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "append assigns increasing seq and take returns ordered events then clears" do
    rid = "rid_#{System.unique_integer([:positive])}"
    :ok = TurnEvents.append(rid, "request_start", %{"a" => 1})
    :ok = TurnEvents.append(rid, "turn_complete", %{"b" => 2})

    events = TurnEvents.take(rid)

    assert [%{"seq" => 1, "type" => "request_start"}, %{"seq" => 2, "type" => "turn_complete"}] =
             events

    assert TurnEvents.take(rid) == []
  end

  test "append_current/take_current key off the process-current id and clear it" do
    rid = "rid_#{System.unique_integer([:positive])}"
    TurnEvents.put_current(rid)
    :ok = TurnEvents.append_current("tool_use", %{"gen_ai.tool.name" => "run_sql"})

    assert [%{"type" => "tool_use", "gen_ai" => %{"gen_ai.tool.name" => "run_sql"}}] =
             TurnEvents.take_current()

    assert TurnEvents.current() == nil
  end

  test "append with a nil id is a no-op" do
    assert TurnEvents.append(nil, "x", %{}) == :ok
    assert TurnEvents.take(nil) == []
  end
end
