defmodule Integration.CloudEventTypesContractTest do
  @moduledoc """
  Guards envelope recognition across lifecycle and record families; analytics
  ingests CloudEvents into `events_raw` by their structure rather than their type
  strings. Each envelope's type reaching `events_raw` unchanged proves transport,
  not the type strings themselves; the routing-decision contract pins the one
  string analytics hard-codes.
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
        {:ok, event} = apply(Event, domain, [type, [seq: 1, ts: 0]])

        {:ok, envelope} =
          CloudEvent.from_event(event,
            id: "ev-#{domain}-#{type}",
            source: @source,
            time: @time
          )

        envelope
      end

    sent = [
      routing_decision: Types.routing_decision(),
      ledger_completion: Types.ledger_completion(),
      eval_outcome: Types.eval_outcome(),
      memory: Types.memory(:proposed)
    ]

    helpers = Types.__info__(:functions) -- [for_event: 1, namespace: 0]

    assert Enum.sort(Keyword.keys(helpers)) == Enum.sort(Keyword.keys(sent)),
           "Mimir.CloudEvent.Types helpers #{inspect(helpers)} differ from those sent here: " <>
             inspect(Keyword.keys(sent))

    records =
      for {type, i} <- Enum.with_index(Keyword.values(sent)) do
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
    expected = envelopes |> Enum.map(& &1.type) |> Enum.sort()
    got = List.flatten(rows)

    missing = expected -- got
    extra = got -- expected

    assert {missing, extra} == {[], []},
           "events_raw lost #{inspect(missing)} and gained #{inspect(extra)}"
  end
end
