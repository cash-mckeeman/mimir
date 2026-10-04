defmodule MimirAnalytics.Mappers.GatewayExportTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers.GatewayExport, Mappers.Session, Store}

  @fixture Path.expand("../../support/run_record_fixtures/gateway_export.jsonl", __DIR__)
  @sessions Path.expand("../../support/run_record_fixtures/session_local.jsonl", __DIR__)

  setup do
    {:ok, store} = Store.open(:memory)
    %{store: store}
  end

  test "maps request_log to model_calls with lineage", %{store: store} do
    {:ok, %{rows: %{"model_calls" => 1, "routing_decisions" => 1}}} =
      GatewayExport.ingest(store, @fixture)

    {:ok, [[rid, vk, pk, wf, step, cost]]} =
      Store.query(store, """
      SELECT mimir_request_id, virtual_key_id, parent_key_id, workflow_id, step_id,
             cost_microdollars FROM model_calls
      """)

    assert {rid, vk, pk} == {"req_9f1", "vk_child_1", "vk_parent_1"}
    assert {wf, step, cost} == {"wf_demo1", "analyze", 1834}
  end

  test "flattens routing_decision verdict + descriptor", %{store: store} do
    {:ok, _} = GatewayExport.ingest(store, @fixture)

    {:ok, [[did, outcome, model, lane, digest]]} =
      Store.query(store, """
      SELECT decision_id, outcome, chosen_model, chosen_lane, agent_digest
      FROM routing_decisions
      """)

    assert did == "rd_abc"
    assert {outcome, model, lane} == {"placement", "nemotron-super-3-120b", "bedrock_reason"}
    assert digest == "sha256:abc123"
  end

  test "resolve_run_ids links model_calls to runs via workflow/step", %{store: store} do
    {:ok, _} = Session.ingest(store, @sessions)
    {:ok, _} = GatewayExport.ingest(store, @fixture)
    :ok = GatewayExport.resolve_run_ids(store)

    {:ok, [[run_id]]} = Store.query(store, "SELECT run_id FROM model_calls")
    assert run_id == "sess_01aaaa"
  end

  test "enveloped turn_events become events_raw rows with envelope columns and a wall-clock ts",
       %{store: store} do
    {:ok, _} = GatewayExport.ingest(store, @fixture)

    {:ok, rows} =
      Store.query(store, """
      SELECT scope_id, domain, type, ce_id, ce_source, ce_type, ts IS NOT NULL
      FROM events_raw
      WHERE source = 'gateway' AND ce_type LIKE 'ai.bizinsights.mimir.llm.%'
      ORDER BY seq
      """)

    assert [[scope_id, "llm", _type, ce_id, ce_source, ce_type, true] | _] = rows
    assert scope_id == "req_9f1"
    assert String.starts_with?(ce_type, "ai.bizinsights.mimir.llm.")
    assert is_binary(ce_id) and is_binary(ce_source)
  end

  test "routing.decision and ledger.completion CloudEvents are kept, with no invented domain/type",
       %{store: store} do
    {:ok, _} = GatewayExport.ingest(store, @fixture)

    {:ok, rows} =
      Store.query(store, """
      SELECT ce_type, domain, type FROM events_raw
      WHERE ce_type IN ('ai.bizinsights.mimir.routing.decision',
                        'ai.bizinsights.mimir.ledger.completion')
      ORDER BY ce_type
      """)

    assert rows == [
             ["ai.bizinsights.mimir.ledger.completion", nil, nil],
             ["ai.bizinsights.mimir.routing.decision", nil, nil]
           ]
  end

  test "a mixed array ingests enveloped and pre-envelope entries side by side", %{store: store} do
    {:ok, _} = GatewayExport.ingest(store, @fixture)

    {:ok, [[enveloped]]} =
      Store.query(store, "SELECT count(*) FROM events_raw WHERE ce_id IS NOT NULL")

    {:ok, [[legacy]]} =
      Store.query(
        store,
        "SELECT count(*) FROM events_raw WHERE source = 'gateway' AND ce_id IS NULL"
      )

    assert enveloped > 0
    assert legacy == 2

    # pre-envelope entries get no fabricated wall-clock
    {:ok, [[0]]} =
      Store.query(
        store,
        "SELECT count(*) FROM events_raw WHERE ce_id IS NULL AND ts IS NOT NULL"
      )
  end

  test "scope_id falls back to the line request_id when an enveloped body omits ids.request_id",
       %{store: store} do
    path = Path.join(System.tmp_dir!(), "gw_noid_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm_rf!(path) end)

    # Envelope attributes copied from the captured fixture's first entry; only
    # the body's `ids` is removed, which is the condition under test.
    line =
      %{
        "kind" => "request_log",
        "request_id" => "req_line",
        "turn_events" => %{
          "events" => [
            %{
              "specversion" => "1.0",
              "id" => "req_line:1",
              "source" => "//gateway.example/test",
              "type" => "ai.bizinsights.mimir.llm.reasoning",
              "time" => "2026-07-25T14:01:10.123Z",
              "datacontenttype" => "application/json",
              "data" => %{"domain" => "llm", "type" => "reasoning", "seq" => 1, "raw" => %{}}
            }
          ]
        }
      }
      |> Jason.encode!()

    File.write!(path, line <> "\n")

    {:ok, _} = GatewayExport.ingest(store, path)

    {:ok, [[scope, ts]]} =
      Store.query(store, "SELECT scope_id, ts FROM events_raw WHERE ce_id = 'req_line:1'")

    assert scope == "req_line"
    assert ts != nil
  end

  test "a bare-list turn_events (hand-written buffer file) is still tolerated", %{store: store} do
    path = Path.join(System.tmp_dir!(), "gw_bare_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm_rf!(path) end)

    File.write!(
      path,
      ~s({"kind":"request_log","request_id":"req_bare","turn_events":[{"domain":"llm","type":"reasoning","seq":1,"ts":10,"raw":{}}]}) <>
        "\n"
    )

    {:ok, _} = GatewayExport.ingest(store, path)

    {:ok, [[scope]]} =
      Store.query(store, "SELECT scope_id FROM events_raw WHERE source = 'gateway'")

    assert scope == "req_bare"
  end

  @tag :tmp_dir
  test "the same contents under a new name are already ingested", %{
    store: store,
    tmp_dir: tmp_dir
  } do
    copy = Path.join(tmp_dir, "copy.jsonl")
    File.cp!(@fixture, copy)

    {:ok, _} = GatewayExport.ingest(store, @fixture)
    assert :already_ingested = GatewayExport.ingest(store, copy)
  end
end
