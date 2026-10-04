defmodule Integration.CloudEventTypesContractTest do
  @moduledoc """
  Guards envelope recognition across lifecycle and record families; analytics
  identifies CloudEvents by their structure rather than their type strings.
  """
  use ExUnit.Case, async: true

  alias Integration.Fixtures
  alias Mimir.{CloudEvent, Event}
  alias Mimir.CloudEvent.Types
  alias MimirAnalytics.{Mappers.GatewayExport, Store}

  @moduletag :tmp_dir
  @source "//gateway.example/integration"
  @time "2026-10-02T00:00:00Z"

  test "each generated type lands in events_raw with its ce_type", %{tmp_dir: dir} do
    lifecycle =
      for {domain, types} <- [
            llm: [
              :request_start,
              :request_stop,
              :reasoning,
              :tool_call,
              :tool_result,
              :usage,
              :turn_complete,
              :exception
            ],
            agent: [:session_open, :session_reattach, :turn_start, :turn_end, :terminal, :error],
            workflow: [:step_start, :step_stop, :step_exception]
          ],
          type <- types do
        {:ok, envelope} =
          CloudEvent.from_event(%Event{domain: domain, type: type, seq: 1, ts: 0},
            id: "ev-#{domain}-#{type}",
            source: @source,
            time: @time
          )

        envelope
      end

    records =
      for {type, i} <-
            Enum.with_index([
              Types.routing_decision(),
              Types.ledger_completion(),
              Types.eval_outcome(),
              Types.memory(:write)
            ]) do
        {:ok, envelope} =
          CloudEvent.new(
            id: "rec-#{i}",
            source: @source,
            type: type,
            time: @time,
            data: %{"seq" => i + 1}
          )

        envelope
      end

    envelopes = lifecycle ++ records
    path = Path.join(dir, "gateway.jsonl")

    line =
      envelopes
      |> Enum.map(&CloudEvent.to_wire/1)
      |> Fixtures.request_log_row()
      |> Map.put("kind", "request_log")

    File.write!(path, Jason.encode!(line) <> "\n")

    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    {:ok, _summary} = GatewayExport.ingest(store, path)

    assert {:ok, rows} = Store.query(store, "SELECT ce_type FROM events_raw ORDER BY ce_type")
    assert List.flatten(rows) == envelopes |> Enum.map(& &1.type) |> Enum.sort()
  end
end
