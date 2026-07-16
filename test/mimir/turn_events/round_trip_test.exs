defmodule Mimir.TurnEvents.RoundTripTest do
  @moduledoc """
  Exercises the buffer end to end: multiple request ids in flight at once,
  each round-tripping independently through append/take, and the taken
  event's wire form round-tripping through `Mimir.Event.to_wire/1`/
  `from_wire/1`.
  """
  use ExUnit.Case, async: false

  alias Mimir.{Event, TurnEvents}

  setup do
    case start_supervised(TurnEvents) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "two concurrent request ids round-trip independently through append/take" do
    rid_a = "rid_a_#{System.unique_integer([:positive])}"
    rid_b = "rid_b_#{System.unique_integer([:positive])}"

    {:ok, a1} = Event.llm(:request_start, request_id: rid_a, raw: %{"a" => 1})
    {:ok, b1} = Event.llm(:tool_call, request_id: rid_b, tool: %{id: "t1", name: "run_sql"})
    {:ok, a2} = Event.llm(:turn_complete, request_id: rid_a, raw: %{"a" => 2})

    :ok = TurnEvents.append(rid_a, a1)
    :ok = TurnEvents.append(rid_b, b1)
    :ok = TurnEvents.append(rid_a, a2)

    assert [
             %Event{seq: 1, type: :request_start, raw: %{"a" => 1}},
             %Event{seq: 2, type: :turn_complete, raw: %{"a" => 2}}
           ] = TurnEvents.take(rid_a)

    assert [%Event{seq: 1, type: :tool_call, tool: %{name: "run_sql"}}] = TurnEvents.take(rid_b)

    # Taking clears both — a second take for either id returns empty.
    assert TurnEvents.take(rid_a) == []
    assert TurnEvents.take(rid_b) == []
  end

  test "the taken event's wire form round-trips through to_wire/from_wire" do
    rid = "rid_#{System.unique_integer([:positive])}"
    {:ok, ev} = Event.llm(:tool_call, request_id: rid, tool: %{id: "t1", name: "run_sql"})
    :ok = TurnEvents.append(rid, ev)

    assert [taken] = TurnEvents.take(rid)
    assert {:ok, ^taken} = taken |> Event.to_wire() |> Event.from_wire()
  end
end
