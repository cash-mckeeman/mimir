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

  test "typed raw events pass through under raw_type, decision-correlated" do
    ctx = Mimir.Ingest.new(request_id: "req_3")

    :ok =
      Mimir.Ingest.handle_event(ctx, %{
        "type" => "custom_tool_use",
        "name" => "search",
        "input" => %{"q" => "x"}
      })

    assert [%Event{} = e] = Mimir.TurnEvents.take("req_3")
    assert e.type == :turn_complete
    assert e.raw["raw_type"] == "custom_tool_use"
    assert e.raw["name"] == "search"
    assert e.raw["input"] == %{"q" => "x"}
    refute Map.has_key?(e.raw, "type")
  end

  test "workflow_id/step_id metadata promotes into the event's typed ids" do
    ctx =
      Mimir.Ingest.new(
        request_id: "req_5",
        metadata: %{"workflow_id" => "wf_5", "step_id" => "s5"}
      )

    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "x"})

    assert [%Event{workflow_id: "wf_5", step_id: "s5"}] = Mimir.TurnEvents.take("req_5")
  end

  test "untyped maps are skipped; garbage never raises" do
    ctx = Mimir.Ingest.new(request_id: "req_4")

    assert :ok = Mimir.Ingest.handle_event(ctx, %{"no" => "type"})
    assert :ok = Mimir.Ingest.handle_event(ctx, %{"type" => :not_a_binary})
    assert Mimir.TurnEvents.take("req_4") == []
  end
end
