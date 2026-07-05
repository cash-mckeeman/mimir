defmodule Mimir.IngestTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(Mimir.TurnEvents)
    :ok
  end

  test "from_route/2 builds a correlated context" do
    resp = %{decision_id: "rd_1", workflow_id: "wf", step_id: "s1", verdict: "placement"}
    ctx = Mimir.Ingest.from_route(resp, "req_1")

    assert ctx.request_id == "req_1"
    assert ctx.decision_id == "rd_1"
    assert ctx.metadata == %{"workflow_id" => "wf", "step_id" => "s1"}
  end

  test "text deltas land decision-correlated in the buffer" do
    ctx =
      Mimir.Ingest.new(request_id: "req_2", decision_id: "rd_2", metadata: %{"step_id" => "s"})

    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "hel"})
    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "lo"})

    assert [e1, e2] = Mimir.TurnEvents.take("req_2")
    assert e1["type"] == "text_delta"
    assert e1["gen_ai"]["gen_ai.output.text.delta"] == "hel"
    assert e1["gen_ai"]["decision_id"] == "rd_2"
    assert e1["gen_ai"]["step_id"] == "s"
    assert e2["gen_ai"]["gen_ai.output.text.delta"] == "lo"
  end

  test "typed raw events pass through under their own type" do
    ctx = Mimir.Ingest.new(request_id: "req_3")

    :ok =
      Mimir.Ingest.handle_event(ctx, %{
        "type" => "custom_tool_use",
        "name" => "search",
        "input" => %{"q" => "x"}
      })

    assert [e] = Mimir.TurnEvents.take("req_3")
    assert e["type"] == "custom_tool_use"
    assert e["gen_ai"]["name"] == "search"
    refute Map.has_key?(e["gen_ai"], "type")
  end

  test "untyped maps are skipped; garbage never raises" do
    ctx = Mimir.Ingest.new(request_id: "req_4")

    assert :ok = Mimir.Ingest.handle_event(ctx, %{"no" => "type"})
    assert :ok = Mimir.Ingest.handle_event(ctx, %{"type" => :not_a_binary})
    assert Mimir.TurnEvents.take("req_4") == []
  end
end
