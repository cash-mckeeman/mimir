defmodule Mimir.TurnEvents.RoundTripTest do
  @moduledoc """
  Exercises the buffer end to end: multiple request ids in flight at once,
  each round-tripping independently through append/take, and the persisted
  envelope shape matching what `envelope/4` builds from the same fields.
  """
  use ExUnit.Case, async: false

  alias Mimir.TurnEvents

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

    :ok = TurnEvents.append(rid_a, "request_start", %{"a" => 1})
    :ok = TurnEvents.append(rid_b, "tool_use", %{"gen_ai.tool.name" => "run_sql"})
    :ok = TurnEvents.append(rid_a, "turn_complete", %{"a" => 2})

    assert [
             %{"seq" => 1, "type" => "request_start", "gen_ai" => %{"a" => 1}},
             %{"seq" => 2, "type" => "turn_complete", "gen_ai" => %{"a" => 2}}
           ] = TurnEvents.take(rid_a)

    assert [%{"seq" => 1, "type" => "tool_use", "gen_ai" => %{"gen_ai.tool.name" => "run_sql"}}] =
             TurnEvents.take(rid_b)

    # Taking clears both — a second take for either id returns empty.
    assert TurnEvents.take(rid_a) == []
    assert TurnEvents.take(rid_b) == []
  end

  test "the persisted envelope from take/1 matches envelope/4 built from the same fields" do
    rid = "rid_#{System.unique_integer([:positive])}"
    :ok = TurnEvents.append(rid, "tool_use", %{"gen_ai.tool.name" => "run_sql"})

    assert [%{"seq" => seq, "ts" => ts, "type" => type, "gen_ai" => gen_ai} = event] =
             TurnEvents.take(rid)

    assert TurnEvents.envelope(seq, ts, type, gen_ai) == event
  end
end
