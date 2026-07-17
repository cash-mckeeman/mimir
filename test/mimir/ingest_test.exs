defmodule Mimir.IngestTest do
  use ExUnit.Case, async: false

  alias Mimir.Event

  setup do
    start_supervised!(Mimir.TurnEvents)
    :ok
  end

  test "from_route/2 builds a correlated context" do
    {:ok, resp} =
      Mimir.RouteResponse.new(%{
        verdict: "placement",
        placement: %{model: "m"},
        decision_id: "rd_1",
        workflow_id: "wf",
        step_id: "s1"
      })

    ctx = Mimir.Ingest.from_route(resp, "req_1")

    assert ctx.request_id == "req_1"
    assert ctx.decision_id == "rd_1"
    assert ctx.metadata == %{"workflow_id" => "wf", "step_id" => "s1"}
  end

  test "text deltas land decision-correlated, promoted into the typed event" do
    ctx =
      Mimir.Ingest.new(request_id: "req_2", decision_id: "rd_2", metadata: %{"step_id" => "s"})

    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "hel"})
    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "lo"})

    assert [%Event{} = e1, %Event{} = e2] = Mimir.TurnEvents.take("req_2")

    assert e1.domain == :llm
    assert e1.type == :turn_complete
    assert e1.request_id == "req_2"
    assert e1.step_id == "s"
    assert e1.raw["output_text_delta"] == "hel"
    assert e1.raw["raw_type"] == "text_delta"
    assert e1.raw["decision_id"] == "rd_2"
    assert e2.raw["output_text_delta"] == "lo"
  end

  test "tool-call-shaped frames classify as :tool_call, decision-correlated, lossless in raw" do
    ctx = Mimir.Ingest.new(request_id: "req_3")

    :ok =
      Mimir.Ingest.handle_event(ctx, %{
        "type" => "custom_tool_use",
        "name" => "search",
        "input" => %{"q" => "x"}
      })

    assert [%Event{} = e] = Mimir.TurnEvents.take("req_3")
    assert e.type == :tool_call
    assert e.tool == %{id: nil, name: "search"}
    assert e.raw["raw_type"] == "custom_tool_use"
    assert e.raw["name"] == "search"
    assert e.raw["input"] == %{"q" => "x"}
    refute Map.has_key?(e.raw, "type")
  end

  test "tool-call-shaped frames with an id populate the tool commons' id" do
    ctx = Mimir.Ingest.new(request_id: "req_3b")

    :ok =
      Mimir.Ingest.handle_event(ctx, %{"type" => "tool_use", "id" => "t1", "name" => "echo"})

    assert [%Event{type: :tool_call, tool: %{id: "t1", name: "echo"}}] =
             Mimir.TurnEvents.take("req_3b")
  end

  test "usage-bearing frames classify as :usage, decision-correlated, lossless in raw" do
    ctx = Mimir.Ingest.new(request_id: "req_6", decision_id: "rd_6")

    :ok =
      Mimir.Ingest.handle_event(ctx, %{
        "type" => "message_delta",
        "input_tokens" => 10,
        "output_tokens" => 5
      })

    assert [%Event{} = e] = Mimir.TurnEvents.take("req_6")
    assert e.type == :usage
    assert e.usage == %{input_tokens: 10, output_tokens: 5}
    assert e.raw["raw_type"] == "message_delta"
    assert e.raw["input_tokens"] == 10
    assert e.raw["output_tokens"] == 5
    assert e.raw["decision_id"] == "rd_6"
    refute Map.has_key?(e.raw, "type")
  end

  test "genuinely unrecognized frames are dropped, never given a placeholder type, and counted" do
    test_pid = self()
    handler_id = "ingest-unknown-#{System.unique_integer()}"

    :telemetry.attach(
      handler_id,
      [:mimir, :ingest, :unknown_event],
      fn event, measurements, metadata, _config ->
        send(test_pid, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ctx = Mimir.Ingest.new(request_id: "req_7")

    assert :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "some_unrecognized_frame"})

    assert_receive {[:mimir, :ingest, :unknown_event], %{count: 1},
                    %{raw_type: "some_unrecognized_frame"}}

    assert Mimir.TurnEvents.take("req_7") == []
  end

  test "workflow_id/step_id metadata promotes into the event's typed ids" do
    ctx =
      Mimir.Ingest.new(
        request_id: "req_5",
        metadata: %{"workflow_id" => "wf_5", "step_id" => "s5"}
      )

    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "hi"})

    assert [%Event{workflow_id: "wf_5", step_id: "s5"}] = Mimir.TurnEvents.take("req_5")
  end

  test "untyped maps are skipped; garbage never raises" do
    ctx = Mimir.Ingest.new(request_id: "req_4")

    assert :ok = Mimir.Ingest.handle_event(ctx, %{"no" => "type"})
    assert :ok = Mimir.Ingest.handle_event(ctx, %{"type" => :not_a_binary})
    assert Mimir.TurnEvents.take("req_4") == []
  end
end
