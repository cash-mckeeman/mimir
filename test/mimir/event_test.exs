defmodule Mimir.EventTest do
  use ExUnit.Case, async: true
  alias Mimir.Event

  describe "constructors" do
    test "llm/2 builds a typed event" do
      assert {:ok, %Event{domain: :llm, type: :usage, seq: 3}} =
               Event.llm(:usage,
                 seq: 3,
                 ts: 1,
                 request_id: "r1",
                 usage: %{input_tokens: 10, output_tokens: 2}
               )
    end

    test "constructor rejects a type outside its domain" do
      assert {:error, {:bad_type, :llm, :session_open}} = Event.llm(:session_open, seq: 0, ts: 0)
      assert {:ok, _} = Event.agent(:session_open, seq: 0, ts: 0)
      assert {:ok, _} = Event.workflow(:step_start, seq: 0, ts: 0)
    end
  end

  describe "wire round-trip" do
    test "to_wire |> from_wire is identity for each domain" do
      for {:ok, ev} <- [
            Event.llm(:tool_call,
              seq: 1,
              ts: 2,
              request_id: "r",
              tool: %{id: "t1", name: "echo"}
            ),
            Event.agent(:session_reattach, seq: 2, ts: 3, session_id: "s", raw: %{"x" => 1}),
            Event.workflow(:step_stop, seq: 3, ts: 4, workflow_id: "w", step_id: "st")
          ] do
        assert {:ok, ^ev} = ev |> Event.to_wire() |> Event.from_wire()
      end
    end

    test "wire shape: string keys, nil ids omitted" do
      {:ok, ev} = Event.llm(:usage, seq: 1, ts: 2, usage: %{input_tokens: 1, output_tokens: 1})
      wire = Event.to_wire(ev)
      assert wire["domain"] == "llm" and wire["type"] == "usage"
      refute Map.has_key?(wire["ids"], "session_id")
      refute Map.has_key?(wire, "tool")
    end

    test "from_wire is fallible and tolerant" do
      assert {:error, {:bad_event, _}} =
               Event.from_wire(%{"domain" => "llm", "type" => "nope", "seq" => 0, "ts" => 0})

      assert {:error, {:bad_event, _}} = Event.from_wire(%{"nonsense" => true})
      # extra top-level keys ignored
      {:ok, ev} = Event.llm(:reasoning, seq: 0, ts: 0)
      assert {:ok, ^ev} = ev |> Event.to_wire() |> Map.put("future_field", 1) |> Event.from_wire()
    end
  end
end
