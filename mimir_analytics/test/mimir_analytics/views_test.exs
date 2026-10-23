defmodule MimirAnalytics.ViewsTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers.EvalReport, Mappers.GatewayExport, Mappers.Session, Store}

  @fx Path.expand("../support/run_record_fixtures", __DIR__)

  setup do
    {:ok, store} = Store.open(:memory)
    {:ok, _} = Session.ingest(store, Path.join(@fx, "session_local.jsonl"))
    {:ok, _} = GatewayExport.ingest(store, Path.join(@fx, "gateway_export.jsonl"))
    {:ok, _} = EvalReport.ingest(store, Path.join(@fx, "eval_report.json"))
    :ok = GatewayExport.resolve_run_ids(store)
    :ok = MimirAnalytics.Views.apply(store.conn)
    %{store: store}
  end

  test "v_parity_cost: $/passing-case joins eval to run cost", %{store: store} do
    {:ok, rows} =
      Store.query(
        store,
        "SELECT runtime, passing_cases, total_cost_microdollars FROM v_parity_cost"
      )

    assert [["local", 1, 0]] = rows
  end

  test "parity totals stay unknown across missing attempts and missing cases", %{store: store} do
    assert {:ok, _} = Session.ingest(store, Path.join(@fx, "session_execution_facts.jsonl"))

    assert {:ok, _} =
             Store.query(store, "UPDATE runs SET cost_microdollars = 7 WHERE step_id = 'partial'")

    for grouping <- ["'same-case'", "step_id"] do
      assert {:ok, _} = Store.query(store, "DELETE FROM eval_outcomes WHERE agent = 'fixture'")

      assert {:ok, _} =
               Store.query(store, """
               INSERT INTO eval_outcomes (run_id, agent, suite, case_id, passed, source_file)
               SELECT run_id, 'fixture', 'fixture', #{grouping}, true, 'fixture.json'
               FROM runs WHERE workflow_id = 'consumer-contract' AND runtime = 'managed'
               """)

      assert {:ok, [[nil, nil]]} =
               Store.query(store, """
               SELECT total_cost_microdollars, microdollars_per_passing_case
               FROM v_parity_cost WHERE runtime = 'managed'
               """)

      assert {:ok, _} =
               Store.query(
                 store,
                 "UPDATE runs SET cost_microdollars = 9 WHERE step_id = 'unknown'"
               )

      expected_ratio = if grouping == "'same-case'", do: 16.0, else: 8.0

      assert {:ok, [[16, ^expected_ratio]]} =
               Store.query(store, """
               SELECT total_cost_microdollars, microdollars_per_passing_case
               FROM v_parity_cost WHERE runtime = 'managed'
               """)

      assert {:ok, _} =
               Store.query(
                 store,
                 "UPDATE runs SET cost_microdollars = NULL WHERE step_id = 'unknown'"
               )
    end
  end

  test "v_tool_signatures yields the miner's shape hash input", %{store: store} do
    {:ok, [[_run, sig, n]]} =
      Store.query(store, "SELECT run_id, signature, n_tools FROM v_tool_signatures")

    assert sig == "search_kb->emit_narrative"
    assert n == 2
  end

  test "v_flow_tree orders workflow -> step -> run", %{store: store} do
    {:ok, rows} = Store.query(store, "SELECT workflow_id, step_id, run_id FROM v_flow_tree")
    assert [["wf_demo1", "analyze", "sess_01aaaa"]] = rows
  end

  test "v_eval_trend and v_memory_evidence exist and are queryable", %{store: store} do
    {:ok, _} = Store.query(store, "SELECT * FROM v_eval_trend")
    {:ok, _} = Store.query(store, "SELECT * FROM v_memory_evidence")
  end
end
