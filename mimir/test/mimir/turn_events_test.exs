defmodule Mimir.TurnEventsTest do
  use ExUnit.Case, async: false
  alias Mimir.{Event, TurnEvents}

  setup do
    case start_supervised(TurnEvents) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp usage_event(attrs \\ []) do
    {:ok, ev} =
      Event.llm(
        :usage,
        Keyword.merge([seq: 999, ts: 999, usage: %{input_tokens: 1, output_tokens: 1}], attrs)
      )

    ev
  end

  defp tool_event(attrs \\ []) do
    {:ok, ev} =
      Event.llm(
        :tool_call,
        Keyword.merge([seq: 999, ts: 999, tool: %{id: "t1", name: "x"}], attrs)
      )

    ev
  end

  test "append assigns increasing seq, take returns ordered events, then clears" do
    rid = "rid_#{System.unique_integer([:positive])}"
    :ok = TurnEvents.append(rid, usage_event(request_id: rid))
    :ok = TurnEvents.append(rid, tool_event(request_id: rid))

    assert [%Event{seq: 1, type: :usage} = e1, %Event{seq: 2, type: :tool_call} = e2] =
             TurnEvents.take(rid)

    # domain/type/payload survive untouched — only seq/ts are buffer-owned.
    assert e1.domain == :llm
    assert e1.usage == %{input_tokens: 1, output_tokens: 1}
    assert e1.request_id == rid
    assert e2.tool == %{id: "t1", name: "x"}

    assert TurnEvents.take(rid) == []
  end

  test "append overwrites caller-supplied seq/ts with buffer-assigned values" do
    rid = "rid_#{System.unique_integer([:positive])}"
    # Constructor seq/ts (999/999) must not survive into the buffer.
    :ok = TurnEvents.append(rid, usage_event())

    assert [%Event{seq: 1} = ev] = TurnEvents.take(rid)
    assert ev.seq != 999
    assert ev.ts != 999
  end

  test "append_current/take_current key off the process-current id and clear it" do
    rid = "rid_#{System.unique_integer([:positive])}"
    TurnEvents.put_current(rid)
    :ok = TurnEvents.append_current(tool_event())

    assert [%Event{type: :tool_call, tool: %{name: "x"}}] = TurnEvents.take_current()
    assert TurnEvents.current() == nil
  end

  test "append with a nil id is a no-op" do
    assert TurnEvents.append(nil, usage_event()) == :ok
    assert TurnEvents.take(nil) == []
  end

  test "a to_wire snapshot of a taken event matches the wire shape" do
    rid = "rid_#{System.unique_integer([:positive])}"
    :ok = TurnEvents.append(rid, usage_event(request_id: rid))

    assert [ev] = TurnEvents.take(rid)
    wire = Event.to_wire(ev)

    assert wire["domain"] == "llm"
    assert wire["type"] == "usage"
    assert wire["seq"] == 1
    assert wire["ids"] == %{"request_id" => rid}
    assert wire["usage"] == %{"input_tokens" => 1, "output_tokens" => 1}
    assert {:ok, ^ev} = Event.from_wire(wire)
  end

  describe "TTL sweep" do
    test "reclaims a buffer whose rows are older than the TTL window" do
      rid = "rid_orphan_#{System.unique_integer([:positive])}"
      old_ts = System.monotonic_time(:nanosecond) - 121_000_000_000
      ev = usage_event()

      {seq_table, buf_table} =
        Application.get_env(:mimir, :turn_events_tables, {:mimir_turn_seq, :mimir_turn_events})

      :ets.insert(buf_table, {{rid, 1}, old_ts, %Event{ev | seq: 0, ts: 0}})
      :ets.insert(seq_table, {rid, 1, old_ts})

      :ok = TurnEvents.sweep_now()

      assert TurnEvents.take(rid) == []
    end

    test "a live (recently-appended) buffer survives a sweep pass" do
      rid = "rid_live_#{System.unique_integer([:positive])}"
      :ok = TurnEvents.append(rid, usage_event())

      :ok = TurnEvents.sweep_now()

      assert [%Event{}] = TurnEvents.take(rid)
    end
  end
end
