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
end
