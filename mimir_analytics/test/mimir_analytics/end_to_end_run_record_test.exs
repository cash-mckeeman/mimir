defmodule MimirAnalytics.EndToEndRunRecordTest do
  @moduledoc """
  Proves the full chain for the RunRecord capture seam: a producer-generated
  fixture (`run_record.jsonl`, written by a real run-record producer,
  not hand-built — see `test/support/run_record_fixtures/README.md`) lands
  through `Mappers.Session.ingest/2` and the two views that only need a run
  row carry that fixture's own values (`run_id`, `workflow_id`/`step_id`,
  and the tool signature) — not merely some non-null row.

  `v_parity_cost` and `v_memory_evidence` are deliberately not asserted here:
  the former needs a parity run's eval report joined to a captured record for
  the same session id (neither producer runs in this test), and the latter
  reads `memory_provenance`, which has no producer anywhere in the codebase.
  Both are documented gaps, not bugs in this seam.
  """

  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers, Store, Views}

  @fixture Path.expand("../support/run_record_fixtures/run_record.jsonl", __DIR__)

  setup do
    {:ok, store} = Store.open(:memory)
    :ok = Views.apply(store.conn)
    %{store: store}
  end

  test "the flow-tree and tool-signature views return the fixture's own row", %{store: store} do
    {:ok, _} = Mappers.Session.ingest(store, @fixture)

    assert {:ok, [[run_id, workflow_id, step_id]]} =
             Store.query(store, "SELECT run_id, workflow_id, step_id FROM v_flow_tree")

    assert run_id == "sess_fixture"
    assert workflow_id == "wf_1"
    assert step_id == "analyze"

    assert {:ok, [[run_id, signature, n_tools]]} =
             Store.query(store, "SELECT run_id, signature, n_tools FROM v_tool_signatures")

    assert run_id == "sess_fixture"
    assert signature == "run_sql->run_sql"
    assert n_tools == 2
  end

  # Mappers.Session.ingest/2 checks the ingest ledger directly (Store.ingested?/2)
  # and short-circuits to :already_ingested — it never moves the source file.
  # (The spool-archiving move to `.ingested/` lives one layer up, in
  # Mix.Tasks.MimirAnalytics.Ingest, which this test does not go through.) So
  # re-ingesting the same path here changes nothing because the ledger already
  # has an entry for this file's basename, not because the file went missing.
  test "re-ingesting the same file changes nothing", %{store: store} do
    {:ok, _} = Mappers.Session.ingest(store, @fixture)
    {:ok, before} = Store.query(store, "SELECT count(*) FROM runs")

    assert :already_ingested = Mappers.Session.ingest(store, @fixture)

    assert Store.query(store, "SELECT count(*) FROM runs") == {:ok, before}
  end
end
