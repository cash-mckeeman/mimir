defmodule Mimir.CloudEvent.WireGoldenTest do
  use ExUnit.Case, async: true

  alias Mimir.CloudEvent
  alias Mimir.Event

  # Frozen wire shape for a lifecycle event wrapped as a CloudEvent. Downstream
  # producers and consumers depend on these exact keys; a change here is a
  # consumer-visible change and must be a deliberate one, not a side effect.
  #
  # `seq`/`ts` are supplied explicitly so the golden is deterministic — the
  # event's own `ts` is monotonic and would otherwise vary per run.
  @wire %{
    "specversion" => "1.0",
    "id" => "req_1:2",
    "source" => "//mimir.bizinsights.ai/gateway/prod-1",
    "type" => "ai.bizinsights.mimir.llm.tool_call",
    "time" => "2026-07-25T14:01:10.123Z",
    "subject" => "req_1",
    "datacontenttype" => "application/json",
    "data" => %{
      "domain" => "llm",
      "type" => "tool_call",
      "seq" => 2,
      "ts" => 1_234_567_890,
      "ids" => %{"request_id" => "req_1", "workflow_id" => "wf_9"},
      "raw" => %{"vendor" => "acme"},
      "tool" => %{"id" => "tu_1", "name" => "get_rows"},
      "path" => ["workflow:wf_9", "workflow_step:step_5"]
    }
  }

  setup do
    {:ok, event} =
      Event.llm(:tool_call,
        seq: 2,
        ts: 1_234_567_890,
        request_id: "req_1",
        workflow_id: "wf_9",
        tool: %{id: "tu_1", name: "get_rows"},
        path: ["workflow:wf_9", "workflow_step:step_5"],
        raw: %{"vendor" => "acme"}
      )

    {:ok, ce} =
      CloudEvent.from_event(event,
        id: "req_1:2",
        source: "//mimir.bizinsights.ai/gateway/prod-1",
        time: "2026-07-25T14:01:10.123Z",
        subject: "req_1"
      )

    %{event: event, ce: ce}
  end

  test "to_wire/1 renders the frozen envelope shape", %{ce: ce} do
    assert CloudEvent.to_wire(ce) == @wire
  end

  test "the envelope survives a real JSON encode/decode trip", %{ce: ce} do
    json = ce |> CloudEvent.to_wire() |> Jason.encode!()

    assert Jason.decode!(json) == @wire
  end

  test "from_wire/1 reconstructs the struct across JSON", %{ce: ce} do
    decoded = ce |> CloudEvent.to_wire() |> Jason.encode!() |> Jason.decode!()

    assert CloudEvent.from_wire(decoded) == {:ok, ce}
  end

  test "the wrapped body decodes back to the original event", %{event: event, ce: ce} do
    decoded = ce |> CloudEvent.to_wire() |> Jason.encode!() |> Jason.decode!()
    {:ok, parsed} = CloudEvent.from_wire(decoded)

    assert Event.from_wire(parsed.data) == {:ok, event}
  end
end
