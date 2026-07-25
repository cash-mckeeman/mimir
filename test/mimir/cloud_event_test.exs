defmodule Mimir.CloudEventTest do
  use ExUnit.Case, async: true

  alias Mimir.CloudEvent

  test "new/1 builds a valid envelope with defaults" do
    {:ok, ce} =
      CloudEvent.new(%{
        id: "req_1:2",
        source: "//mimir.bizinsights.ai/gateway/prod-1",
        type: "ai.bizinsights.mimir.llm.tool_call",
        time: "2026-07-25T14:01:10.123Z",
        subject: "req_1",
        data: %{"k" => "v"}
      })

    assert ce.specversion == "1.0"
    assert ce.datacontenttype == "application/json"
    assert ce.id == "req_1:2"
    assert ce.data == %{"k" => "v"}
  end

  test "new/1 defaults time/subject to nil and data to %{}" do
    {:ok, ce} =
      CloudEvent.new(%{id: "i", source: "s", type: "ai.bizinsights.mimir.routing.decision"})

    assert ce.time == nil
    assert ce.subject == nil
    assert ce.data == %{}
  end

  test "new/1 rejects a blank or missing required field" do
    for missing <- [:id, :source, :type] do
      attrs = Map.delete(%{id: "i", source: "s", type: "t"}, missing)
      assert {:error, {:bad_cloudevent, {:missing, ^missing}}} = CloudEvent.new(attrs)
    end

    assert {:error, {:bad_cloudevent, {:missing, :id}}} =
             CloudEvent.new(%{id: "", source: "s", type: "t"})
  end

  test "new/1 rejects a malformed time but accepts RFC3339" do
    base = %{id: "i", source: "s", type: "t"}

    assert {:error, {:bad_cloudevent, {:bad_time, "nope"}}} =
             CloudEvent.new(Map.put(base, :time, "nope"))

    assert {:ok, _} = CloudEvent.new(Map.put(base, :time, "2026-07-25T14:01:10Z"))
  end

  test "new/1 rejects a blank subject but allows an absent or non-empty one" do
    base = %{id: "i", source: "s", type: "t"}

    assert {:error, {:bad_cloudevent, {:blank, :subject}}} =
             CloudEvent.new(Map.put(base, :subject, ""))

    assert {:ok, %{subject: nil}} = CloudEvent.new(base)
    assert {:ok, %{subject: "req_1"}} = CloudEvent.new(Map.put(base, :subject, "req_1"))
  end

  test "valid_time?/1 requires an RFC3339 string with offset" do
    assert CloudEvent.valid_time?("2026-07-25T14:01:10Z")
    assert CloudEvent.valid_time?("2026-07-25T14:01:10.5+02:00")
    refute CloudEvent.valid_time?("2026-07-25T14:01:10")
    refute CloudEvent.valid_time?("not a time")
    refute CloudEvent.valid_time?(nil)
  end

  describe "wire" do
    setup do
      {:ok, ce} =
        CloudEvent.new(%{
          id: "req_1:2",
          source: "//mimir.bizinsights.ai/gateway/prod-1",
          type: "ai.bizinsights.mimir.llm.tool_call",
          time: "2026-07-25T14:01:10Z",
          subject: "req_1",
          data: %{"k" => "v"}
        })

      %{ce: ce}
    end

    test "to_wire/1 emits top-level CloudEvents keys", %{ce: ce} do
      w = CloudEvent.to_wire(ce)

      assert w["specversion"] == "1.0"
      assert w["id"] == "req_1:2"
      assert w["source"] == "//mimir.bizinsights.ai/gateway/prod-1"
      assert w["type"] == "ai.bizinsights.mimir.llm.tool_call"
      assert w["datacontenttype"] == "application/json"
      assert w["time"] == "2026-07-25T14:01:10Z"
      assert w["subject"] == "req_1"
      assert w["data"] == %{"k" => "v"}
    end

    test "to_wire/1 omits nil time and subject" do
      {:ok, ce} = CloudEvent.new(%{id: "i", source: "s", type: "t"})
      w = CloudEvent.to_wire(ce)
      refute Map.has_key?(w, "time")
      refute Map.has_key?(w, "subject")
      assert w["data"] == %{}
    end

    test "from_wire/1 round-trips to_wire/1", %{ce: ce} do
      assert {:ok, ce} == CloudEvent.from_wire(CloudEvent.to_wire(ce))
    end

    test "from_wire/1 is tolerant: bad time -> nil, non-map data -> %{}, unknown keys ignored" do
      {:ok, ce} =
        CloudEvent.from_wire(%{
          "specversion" => "1.0",
          "id" => "i",
          "source" => "s",
          "type" => "t",
          "time" => 123,
          "data" => "not-a-map",
          "extra" => "ignored"
        })

      assert ce.time == nil
      assert ce.data == %{}
    end

    test "from_wire/1 rejects missing required attrs and a bad specversion" do
      base = %{"specversion" => "1.0", "id" => "i", "source" => "s", "type" => "t"}

      assert {:error, {:bad_cloudevent, {:missing, "id"}}} =
               CloudEvent.from_wire(Map.delete(base, "id"))

      assert {:error, {:bad_cloudevent, {:unsupported_specversion, "0.3"}}} =
               CloudEvent.from_wire(Map.put(base, "specversion", "0.3"))

      assert {:error, {:bad_cloudevent, {:invalid_wire, "x"}}} = CloudEvent.from_wire("x")
    end
  end

  describe "from_event/2" do
    setup do
      {:ok, event} =
        Mimir.Event.llm(:tool_call,
          request_id: "req_1",
          seq: 2,
          tool: %{id: "tu_1", name: "get_rows"}
        )

      %{event: event}
    end

    test "sets type from the taxonomy and data from Event.to_wire/1", %{event: event} do
      {:ok, ce} =
        CloudEvent.from_event(event,
          id: "req_1:2",
          source: "//mimir.bizinsights.ai/gateway/prod-1",
          time: "2026-07-25T14:01:10Z",
          subject: "req_1"
        )

      assert ce.type == "ai.bizinsights.mimir.llm.tool_call"
      assert ce.data == Mimir.Event.to_wire(event)
      assert ce.id == "req_1:2"
      assert ce.source == "//mimir.bizinsights.ai/gateway/prod-1"
      assert ce.time == "2026-07-25T14:01:10Z"
      assert ce.subject == "req_1"
    end

    test "inherits new/1 validation — missing producer id errors", %{event: event} do
      assert {:error, {:bad_cloudevent, {:missing, :id}}} =
               CloudEvent.from_event(event, source: "s")
    end
  end
end
