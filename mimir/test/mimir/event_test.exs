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

    test "path defaults to []" do
      {:ok, ev} = Event.llm(:usage, seq: 0, ts: 0, usage: %{input_tokens: 1, output_tokens: 1})
      assert ev.path == []
    end

    test "constructor accepts a well-formed multi-frame path" do
      path = ["workflow:wf_123", "workflow_step:step_5", "agent:sess_9"]
      assert {:ok, %Event{path: ^path}} = Event.workflow(:step_start, seq: 0, ts: 0, path: path)
    end

    test "constructor accepts every closed frame kind" do
      for kind <- ~w(workflow workflow_step agent conversation) do
        frame = "#{kind}:id1"
        assert {:ok, %Event{path: [^frame]}} = Event.llm(:usage, seq: 0, ts: 0, path: [frame])
      end
    end

    test "constructor rejects a frame with a kind outside the closed union" do
      assert {:error, {:bad_frame, "req:r1"}} =
               Event.llm(:usage, seq: 0, ts: 0, path: ["req:r1"])

      # short-form kinds are not part of the union — full words only
      for frame <- ["wf:wf_1", "step:step_1", "conv:c_1"] do
        assert {:error, {:bad_frame, ^frame}} = Event.llm(:usage, seq: 0, ts: 0, path: [frame])
      end
    end

    test "constructor rejects a frame with an empty id" do
      assert {:error, {:bad_frame, "workflow:"}} =
               Event.llm(:usage, seq: 0, ts: 0, path: ["workflow:"])
    end

    test "constructor rejects a non-binary frame" do
      assert {:error, {:bad_frame, :not_a_string}} =
               Event.llm(:usage, seq: 0, ts: 0, path: [:not_a_string])
    end

    test "constructor rejects a frame with no colon separator" do
      assert {:error, {:bad_frame, "wf_123"}} =
               Event.llm(:usage, seq: 0, ts: 0, path: ["wf_123"])
    end

    test "constructor reports the first bad frame among several good ones" do
      assert {:error, {:bad_frame, "bogus:x"}} =
               Event.llm(:usage,
                 seq: 0,
                 ts: 0,
                 path: ["workflow:wf_1", "bogus:x", "workflow_step:step_1"]
               )
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

    test "to_wire |> from_wire is identity when path is non-empty, per domain" do
      path = ["workflow:wf_123", "workflow_step:step_5", "agent:sess_9"]

      for {:ok, ev} <- [
            Event.llm(:tool_call, seq: 1, ts: 2, tool: %{id: "t1", name: "echo"}, path: path),
            Event.agent(:session_reattach, seq: 2, ts: 3, session_id: "s", path: path),
            Event.workflow(:step_stop, seq: 3, ts: 4, workflow_id: "w", step_id: "st", path: path)
          ] do
        assert {:ok, ^ev} = ev |> Event.to_wire() |> Event.from_wire()
        assert ev.path == path
      end
    end

    test "wire shape: string keys, nil ids omitted" do
      {:ok, ev} = Event.llm(:usage, seq: 1, ts: 2, usage: %{input_tokens: 1, output_tokens: 1})
      wire = Event.to_wire(ev)
      assert wire["domain"] == "llm" and wire["type"] == "usage"
      refute Map.has_key?(wire["ids"], "session_id")
      refute Map.has_key?(wire, "tool")
    end

    test "wire shape: \"path\" key omitted when path is empty" do
      {:ok, ev} = Event.llm(:usage, seq: 1, ts: 2, usage: %{input_tokens: 1, output_tokens: 1})
      refute Map.has_key?(Event.to_wire(ev), "path")
    end

    test "wire shape: \"path\" key present with the frame list when non-empty" do
      {:ok, ev} =
        Event.workflow(:step_start,
          seq: 0,
          ts: 0,
          path: ["workflow:wf_1", "workflow_step:step_1"]
        )

      assert Event.to_wire(ev)["path"] == ["workflow:wf_1", "workflow_step:step_1"]
    end

    test "from_wire is fallible and tolerant" do
      assert {:error, {:bad_event, _}} =
               Event.from_wire(%{"domain" => "llm", "type" => "nope", "seq" => 0, "ts" => 0})

      assert {:error, {:bad_event, _}} = Event.from_wire(%{"nonsense" => true})
      # extra top-level keys ignored
      {:ok, ev} = Event.llm(:reasoning, seq: 0, ts: 0)
      assert {:ok, ^ev} = ev |> Event.to_wire() |> Map.put("future_field", 1) |> Event.from_wire()
    end

    test "from_wire with an unrecognized domain string" do
      assert {:error, {:bad_event, {:bad_domain, "bogus"}}} =
               Event.from_wire(%{"domain" => "bogus", "type" => "usage", "seq" => 0, "ts" => 0})
    end

    test "from_wire tolerates non-map ids/raw, degrading to %{}" do
      {:ok, ev} =
        Event.from_wire(%{
          "domain" => "llm",
          "type" => "usage",
          "seq" => 0,
          "ts" => 0,
          "ids" => "not-a-map",
          "raw" => 123
        })

      assert ev.request_id == nil
      assert ev.workflow_id == nil
      assert ev.step_id == nil
      assert ev.session_id == nil
      assert ev.raw == %{}
    end

    test "from_wire: missing \"path\" key degrades to []" do
      {:ok, ev} = Event.from_wire(%{"domain" => "llm", "type" => "usage", "seq" => 0, "ts" => 0})
      assert ev.path == []
    end

    test "from_wire: non-list \"path\" degrades to []" do
      {:ok, ev} =
        Event.from_wire(%{
          "domain" => "llm",
          "type" => "usage",
          "seq" => 0,
          "ts" => 0,
          "path" => "workflow:wf_1"
        })

      assert ev.path == []
    end

    test "from_wire: a path containing one shape-invalid frame degrades the whole path to []" do
      # "no-colon-here" has no "kind:id" shape at all — genuinely malformed,
      # not merely an unrecognized kind.
      {:ok, ev} =
        Event.from_wire(%{
          "domain" => "llm",
          "type" => "usage",
          "seq" => 0,
          "ts" => 0,
          "path" => ["workflow:wf_1", "no-colon-here"]
        })

      assert ev.path == []
    end

    test "from_wire: a frame with an empty kind or id degrades the whole path to []" do
      for bad <- [":id_only", "kind_only:", :not_a_string] do
        {:ok, ev} =
          Event.from_wire(%{
            "domain" => "llm",
            "type" => "usage",
            "seq" => 0,
            "ts" => 0,
            "path" => ["workflow:wf_1", bad]
          })

        assert ev.path == [], "expected #{inspect(bad)} to degrade the path"
      end
    end

    test "from_wire: an unrecognized-but-well-formed kind passes through intact" do
      # F1 forward-compat: a newer producer may emit a frame kind this release
      # does not know. from_wire validates SHAPE only, so the whole path (and
      # the unknown frame) survives — an additive kind must not become a
      # reader-breaking change. Construction still rejects unknown kinds.
      path = ["workflow:wf_1", "tool:t_9", "agent:sess_2"]

      {:ok, ev} =
        Event.from_wire(%{
          "domain" => "llm",
          "type" => "usage",
          "seq" => 0,
          "ts" => 0,
          "path" => path
        })

      assert ev.path == path
      # the same unknown-kind frame is rejected on construction (closed union)
      assert {:error, {:bad_frame, "tool:t_9"}} =
               Event.llm(:usage, seq: 0, ts: 0, path: ["tool:t_9"])
    end

    test "from_wire: a well-formed path round-trips through" do
      {:ok, ev} =
        Event.from_wire(%{
          "domain" => "llm",
          "type" => "usage",
          "seq" => 0,
          "ts" => 0,
          "path" => ["workflow:wf_1", "workflow_step:step_1"]
        })

      assert ev.path == ["workflow:wf_1", "workflow_step:step_1"]
    end
  end
end
