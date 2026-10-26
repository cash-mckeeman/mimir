Code.require_file("test/support/accounting_interop_helper.exs")

defmodule MimirAnalytics.GatewayAccountingUpgradeTest do
  use ExUnit.Case, async: true
  import MimirAnalytics.AccountingInteropHelper

  alias MimirAnalytics.{Mappers, Schema, Store, Views}
  alias MimirAnalytics.Mappers.GatewayExport

  @legacy_tables ~w(workflow_runs steps runs turns tool_calls model_calls routing_decisions eval_outcomes events_raw memory_provenance ingest_rejections)

  @tag :tmp_dir
  test "a closed baseline database upgrades twice, retains legacy rows, and rebuilds from buffers",
       %{tmp_dir: dir} do
    db_path = Path.join(dir, "retained.duckdb")
    {:ok, db} = Duckdbex.open(db_path)
    {:ok, conn} = Duckdbex.connection(db)
    {:ok, _} = Duckdbex.query(conn, "LOAD json")
    {:ok, _} = Duckdbex.query(conn, "LOAD core_functions")
    baseline_sql(conn, "schema")
    baseline_sql(conn, "views")
    old = %Store{db: db, conn: conn}
    ingest_legacy(old)
    before = legacy_snapshot(old)
    assert_legacy_facts(old)
    assert {:error, _} = Store.query(old, "SELECT * FROM accounting_states")
    :ok = Store.close(old)

    {:ok, upgraded} = Store.open(db_path)
    assert :ok = Schema.apply(upgraded.conn)
    assert :ok = Schema.apply(upgraded.conn)
    assert legacy_snapshot(upgraded) == before

    for table <- ~w(accounting_events accounting_states gateway_checkpoints) do
      assert {:ok, [[0]]} = Store.query(upgraded, "SELECT count(*) FROM #{table}")
    end

    buffer = wrapper(dir, wire("producer")["rows"], "retained-page")

    assert {:ok, %{rows: %{"accounting_events" => 5, "accounting_states" => 3}}} =
             GatewayExport.ingest(upgraded, buffer)

    assert :already_ingested = GatewayExport.ingest(upgraded, buffer)
    assert_main_facts(upgraded)
    assert legacy_snapshot(upgraded) == before
    expected = accounting_snapshot(upgraded)
    :ok = Store.close(upgraded)

    {:ok, reopened} = Store.open(db_path)
    assert_main_facts(reopened)
    assert_legacy_facts(reopened)
    assert :already_ingested = GatewayExport.ingest(reopened, buffer)
    assert {:ok, [[6]]} = Store.query(reopened, "SELECT count(*) FROM ingest_ledger")
    assert {:ok, [[0]]} = Store.query(reopened, "SELECT count(*) FROM gateway_checkpoints")
    assert legacy_snapshot(reopened) == before
    assert accounting_snapshot(reopened) == expected
    :ok = Store.close(reopened)

    {:ok, rebuilt} = Store.open(Path.join(dir, "rebuilt.duckdb"))
    ingest_legacy(rebuilt)
    :ok = Views.apply(rebuilt.conn)
    assert {:ok, _} = GatewayExport.ingest(rebuilt, buffer)
    assert :already_ingested = GatewayExport.ingest(rebuilt, buffer)
    assert_main_facts(rebuilt)
    assert_legacy_facts(rebuilt)
    assert legacy_snapshot(rebuilt) == before
    assert accounting_snapshot(rebuilt) == expected
    :ok = Store.close(rebuilt)
  end

  defp baseline_sql(conn, name) do
    "test/support/accounting/baseline/#{name}.sql"
    |> File.read!()
    |> String.split(";", trim: true)
    |> Enum.each(fn sql -> assert {:ok, _} = Duckdbex.query(conn, sql) end)
  end

  defp ingest_legacy(store) do
    for {mapper, name} <- [
          {Mappers.Session, "session_local.jsonl"},
          {Mappers.Session, "run_record.jsonl"},
          {Mappers.Session, "session_execution_facts.jsonl"},
          {GatewayExport, "gateway_export.jsonl"},
          {Mappers.EvalReport, "eval_report.json"}
        ] do
      assert {:ok, _} = mapper.ingest(store, "test/support/run_record_fixtures/" <> name)
    end
  end

  defp legacy_snapshot(store) do
    for table <- @legacy_tables ++ ~w(v_parity_cost v_flow_tree v_tool_signatures), into: %{} do
      {:ok, rows} = Store.query(store, "SELECT * FROM #{table} ORDER BY ALL")
      {table, rows}
    end
  end

  defp assert_legacy_facts(store) do
    assert {:ok, [["sess_01aaaa", "local", 0], ["sess_fixture", "managed", nil]]} =
             Store.query(
               store,
               "SELECT run_id, runtime, cost_microdollars FROM runs WHERE workflow_id != 'consumer-contract' ORDER BY run_id"
             )

    assert {:ok,
            [
              ["partial", 12, 4, 3, 2, "inclusive", true, "unknown", nil],
              ["unknown", nil, nil, nil, nil, nil, nil, nil, nil],
              ["zero", 0, 0, 0, 0, "inclusive", true, "none", nil]
            ]} =
             Store.query(store, """
             SELECT step_id, input_tokens, output_tokens, cache_read_input_tokens,
                    cache_creation_input_tokens, input_token_basis, usage_complete,
                    in_flight, cost_microdollars FROM runs
             WHERE workflow_id = 'consumer-contract' ORDER BY step_id
             """)

    assert {:ok, [["req_9f1", 1834]]} =
             Store.query(store, "SELECT mimir_request_id, cost_microdollars FROM model_calls")

    assert {:ok, [[5, 3, 2]]} =
             Store.query(store, """
             SELECT count(*), count(ce_id), count(*) FILTER (WHERE ce_id IS NULL) FROM events_raw
             """)

    assert {:ok, [["local", 1, 0, +0.0]]} = Store.query(store, "SELECT * FROM v_parity_cost")

    assert {:ok, [[5]]} =
             Store.query(
               store,
               "SELECT count(*) FROM ingest_ledger WHERE source != 'gateway_accounting'"
             )
  end
end
