defmodule MimirAnalytics.Mappers.EvalReportTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers.EvalReport, Store}

  @fixture Path.expand("../../support/run_record_fixtures/eval_report.json", __DIR__)

  setup do
    {:ok, store} = Store.open(:memory)
    %{store: store}
  end

  test "one row per case, judge fields joined, run_id linked", %{store: store} do
    assert {:ok, %{rows: %{"eval_outcomes" => 2}}} = EvalReport.ingest(store, @fixture)

    {:ok, rows} =
      Store.query(
        store,
        "SELECT case_id, passed, run_id, judge_passed FROM eval_outcomes ORDER BY case_id"
      )

    assert [
             ["case_01_synthetic", true, "sess_01aaaa", true],
             ["case_02_synthetic", false, "sess_01bbbb", nil]
           ] = rows
  end

  test "idempotent by file", %{store: store} do
    {:ok, _} = EvalReport.ingest(store, @fixture)
    assert :already_ingested = EvalReport.ingest(store, @fixture)
    {:ok, [[2]]} = Store.query(store, "SELECT count(*) FROM eval_outcomes")
  end

  @tag :tmp_dir
  test "a report rewritten after ingest is rejected, not added twice", %{
    store: store,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "eval_report.json")
    File.cp!(@fixture, path)
    {:ok, _} = EvalReport.ingest(store, path)

    File.write!(path, File.read!(@fixture) <> "\n")

    assert {:error, {:changed_after_ingest, "eval_report.json"}} = EvalReport.ingest(store, path)
    assert :already_rejected = EvalReport.ingest(store, path)
    assert {:ok, [[2]]} = Store.query(store, "SELECT count(*) FROM eval_outcomes")
  end

  @tag :tmp_dir
  test "the same contents under a new name are already ingested", %{
    store: store,
    tmp_dir: tmp_dir
  } do
    copy = Path.join(tmp_dir, "copy.json")
    File.cp!(@fixture, copy)

    {:ok, _} = EvalReport.ingest(store, @fixture)
    assert :already_ingested = EvalReport.ingest(store, copy)
  end

  @tag :tmp_dir
  test "an empty report is rejected once and left in place", %{store: store, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.json")
    File.write!(path, "")

    assert {:error, :empty_file} = EvalReport.ingest(store, path)
    assert :already_rejected = EvalReport.ingest(store, path)
    assert File.exists?(path)
  end
end
