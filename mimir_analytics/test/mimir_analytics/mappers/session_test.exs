defmodule MimirAnalytics.Mappers.SessionTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers.Session, Store}

  @fixture Path.expand("../../support/run_record_fixtures/session_local.jsonl", __DIR__)

  setup do
    {:ok, store} = Store.open(:memory)
    %{store: store}
  end

  test "runs row carries the correlation contract + usage", %{store: store} do
    {:ok, %{rows: %{"runs" => 1, "tool_calls" => 2}}} = Session.ingest(store, @fixture)

    {:ok, [[run_id, wf, step, digest, runtime, terminal, turns, in_t, out_t]]} =
      Store.query(store, """
      SELECT run_id, workflow_id, step_id, agent_digest, runtime, terminal,
             turns, input_tokens, output_tokens FROM runs
      """)

    # run_id resolves from result.session_id, not meta (this fixture's meta
    # carries "capture_key", the new contract's name — never "run_id").
    assert run_id == "sess_01aaaa"
    assert {wf, step} == {"wf_demo1", "analyze"}
    assert digest == "sha256:abc123"
    assert runtime == "local"
    assert terminal == "end_turn"
    assert {turns, in_t, out_t} == {3, 8123, 1201}
  end

  @legacy_fixture Path.expand(
                    "../../support/run_record_fixtures/session_legacy_run_id_fallback.jsonl",
                    __DIR__
                  )

  test "a legacy capture line (meta.run_id, no result.session_id) still ingests via the documented fallback",
       %{store: store} do
    {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, @legacy_fixture)

    {:ok, [[run_id, wf]]} = Store.query(store, "SELECT run_id, workflow_id FROM runs")

    assert run_id == "sess_legacy_001"
    assert wf == "wf_legacy"
  end

  @tag :tmp_dir
  test "a session_id and a differing legacy meta.run_id both present — session_id wins end-to-end",
       %{store: store, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "precedence.jsonl")

    line =
      %{
        "meta" => %{"run_id" => "legacy_shadow", "workflow_id" => "wf_prec"},
        "result" => %{"session_id" => "sess_authoritative", "outcome" => "ok"}
      }
      |> Jason.encode!()

    File.write!(path, line <> "\n")

    assert {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, path)
    {:ok, [[run_id]]} = Store.query(store, "SELECT run_id FROM runs")
    assert run_id == "sess_authoritative"
  end

  test "tool_calls preserve order + kind; raw events land in events_raw", %{store: store} do
    {:ok, _} = Session.ingest(store, @fixture)

    {:ok, tools} =
      Store.query(store, "SELECT seq, name, kind FROM tool_calls ORDER BY seq")

    assert [[1, "search_kb", "custom"], [2, "emit_narrative", "custom"]] = tools

    {:ok, [[n]]} = Store.query(store, "SELECT count(*) FROM events_raw WHERE source = 'session'")
    assert n == 0
  end

  test "the session capture seam yields no events_raw rows — the producer emits none", %{
    store: store
  } do
    {:ok, %{rows: %{"events_raw" => 0}}} = Session.ingest(store, @fixture)

    {:ok, rows} = Store.query(store, "SELECT count(*) FROM events_raw WHERE source = 'session'")
    assert rows == [[0]]
  end

  # Mapper behavior, NOT a producer contract: this map is written inline and
  # labelled as synthetic on purpose. No capture-seam producer emits an
  # "events" key today (see Mappers.Session's moduledoc); if one ever does,
  # this assertion is replaced by a captured fixture, not extended.
  @tag :tmp_dir
  test "when a source result does carry events, domain and seq flow through", %{
    store: store,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "synthetic_events.jsonl")

    line =
      %{
        "meta" => %{"workflow_id" => "wf_syn"},
        "result" => %{
          "session_id" => "sess_syn",
          "outcome" => "ok",
          "events" => [%{"type" => "t1", "seq" => 1, "domain" => "llm"}, %{"type" => "t2"}]
        }
      }
      |> Jason.encode!()

    File.write!(path, line <> "\n")

    {:ok, _} = Session.ingest(store, path)

    {:ok, rows} =
      Store.query(
        store,
        "SELECT seq, domain, ts FROM events_raw WHERE source = 'session' ORDER BY seq"
      )

    assert rows == [[1, "llm", nil], [2, nil, nil]]
  end

  test "idempotent", %{store: store} do
    {:ok, _} = Session.ingest(store, @fixture)
    assert :already_ingested = Session.ingest(store, @fixture)
  end

  @run_record_fixture Path.expand(
                        "../../support/run_record_fixtures/run_record.jsonl",
                        __DIR__
                      )

  test "a producer-generated RunRecord line lands as this whole runs row", %{store: store} do
    assert {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, @run_record_fixture)

    assert runs_row(store) == %{
             "run_id" => "sess_fixture",
             "workflow_id" => "wf_1",
             "step_id" => "analyze",
             "parent_step_id" => nil,
             "tenant_id" => "acme",
             "agent_digest" => nil,
             "agent_name" => "Example.Agent",
             "agent_version" => nil,
             "runtime" => "managed",
             "provider" => nil,
             "model" => nil,
             "lane" => nil,
             "outcome" => "ok",
             "terminal" => nil,
             "stop_reason" => nil,
             "error_class" => nil,
             "turns" => 3,
             "input_tokens" => 1200,
             "output_tokens" => 340,
             "cost_microdollars" => 0,
             "started_at" => {{2026, 8, 13}, {12, 0, 0, 0}},
             "finished_at" => {{2026, 8, 13}, {12, 0, 2, 0}},
             "source_file" => "run_record.jsonl"
           }
  end

  test "RunRecord tool_calls roll-ups expand into count occurrence rows, kind rollup", %{
    store: store
  } do
    {:ok, _} = Session.ingest(store, @run_record_fixture)

    assert {:ok, [["run_sql", 2]]} =
             Store.query(store, "SELECT name, count(*) FROM tool_calls GROUP BY name")

    {:ok, [[kind]]} = Store.query(store, "SELECT DISTINCT kind FROM tool_calls")
    assert kind == "rollup"
  end

  @run_record_rma_terminal_fixture Path.expand(
                                     "../../support/run_record_fixtures/run_record_rma_terminal.jsonl",
                                     __DIR__
                                   )

  test "a RunRecord line with a session verdict lands as this whole runs row",
       %{store: store} do
    assert {:ok, %{rows: %{"runs" => 1}}} =
             Session.ingest(store, @run_record_rma_terminal_fixture)

    assert runs_row(store) == %{
             "run_id" => "sess_rma_terminal",
             "workflow_id" => "wf_2",
             "step_id" => "analyze",
             "parent_step_id" => nil,
             "tenant_id" => "acme",
             "agent_digest" => nil,
             "agent_name" => "Example.Agent",
             "agent_version" => nil,
             "runtime" => "managed",
             "provider" => nil,
             "model" => nil,
             "lane" => nil,
             "outcome" => "ok",
             "terminal" => "end_turn",
             "stop_reason" => "end_turn",
             "error_class" => nil,
             "turns" => 2,
             "input_tokens" => 500,
             "output_tokens" => 120,
             "cost_microdollars" => 0,
             "started_at" => {{2026, 8, 13}, {12, 10, 0, 0}},
             "finished_at" => {{2026, 8, 13}, {12, 10, 1, 0}},
             "source_file" => "run_record_rma_terminal.jsonl"
           }
  end

  @run_record_error_fixture Path.expand(
                              "../../support/run_record_fixtures/run_record_error.jsonl",
                              __DIR__
                            )

  test "a RunRecord line from a failed run lands as this whole runs row", %{store: store} do
    assert {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, @run_record_error_fixture)

    assert runs_row(store) == %{
             "run_id" => "local-E6-IFu9CJPK-jEY_8Rvxbw",
             "workflow_id" => "wf_3",
             "step_id" => "analyze",
             "parent_step_id" => nil,
             "tenant_id" => "acme",
             "agent_digest" => nil,
             "agent_name" => "Example.Agent",
             "agent_version" => nil,
             "runtime" => "managed",
             "provider" => nil,
             "model" => nil,
             "lane" => nil,
             "outcome" => "error",
             "terminal" => nil,
             "stop_reason" => nil,
             "error_class" => "timeout",
             "turns" => nil,
             "input_tokens" => 0,
             "output_tokens" => 0,
             "cost_microdollars" => 0,
             "started_at" => {{2026, 8, 13}, {12, 20, 0, 0}},
             "finished_at" => {{2026, 8, 13}, {12, 20, 5, 0}},
             "source_file" => "run_record_error.jsonl"
           }
  end

  # Synthetic, labelled as such: every captured RunRecord fixture has a null
  # `parent_step_id` and `cost_microdollars`, so none of them can show that
  # those two fields are carried. This line differs from `run_record.jsonl`
  # only in those two values.
  @tag :tmp_dir
  test "a RunRecord line's parent_step_id and cost_microdollars land on the runs row",
       %{store: store, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "synthetic_run_record.jsonl")

    line =
      @run_record_fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"parent_step_id" => "plan", "cost_microdollars" => 4200})
      |> Jason.encode!()

    File.write!(path, line <> "\n")

    assert {:ok, _} = Session.ingest(store, path)
    assert %{"parent_step_id" => "plan", "cost_microdollars" => 4200} = runs_row(store)
  end

  for {label, roll_up} <- [
        {"without a name", %{"count" => 2}},
        {"with a negative count", %{"name" => "run_sql", "count" => -1}},
        {"with a non-integer count", %{"name" => "run_sql", "count" => "2"}}
      ] do
    @tag :tmp_dir
    @tag roll_up: roll_up
    test "a tool_calls roll-up #{label} raises instead of being dropped",
         %{store: store, tmp_dir: tmp_dir, roll_up: roll_up} do
      path = Path.join(tmp_dir, "malformed_roll_up.jsonl")

      line =
        @run_record_fixture
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("tool_calls", [roll_up])
        |> Jason.encode!()

      File.write!(path, line <> "\n")

      assert_raise ArgumentError, ~r/malformed tool_calls roll-up/, fn ->
        Session.ingest(store, path)
      end
    end
  end

  @tag :tmp_dir
  test "a file that disappears before it is read is an error for that file, not a raise",
       %{store: store, tmp_dir: tmp_dir} do
    assert {:error, {:read_failed, :enoent}} =
             Session.ingest(store, Path.join(tmp_dir, "moved_away.jsonl"))
  end

  @dup_fixture Path.expand(
                 "../../support/run_record_fixtures/session_duplicate_run_id.jsonl",
                 __DIR__
               )

  @tag :tmp_dir
  test "crash mid-batch (PK collision on the second run) leaves zero rows and no ledger entry; re-run then succeeds",
       %{store: store, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "crash.jsonl")
    File.cp!(@dup_fixture, path)

    assert {:error, {:insert_failed, "runs", _reason}} = Session.ingest(store, path)

    {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM runs")
    {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM tool_calls")
    {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM events_raw")
    {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")

    # Fix the file in place (unique run_ids) under the same source_file name
    # and re-ingest: the failed attempt must not have wedged the connection
    # or left a stray ledger/row behind.
    File.cp!(@fixture, path)
    assert {:ok, %{rows: %{"runs" => 1, "tool_calls" => 2}}} = Session.ingest(store, path)
    {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM runs")
    assert Store.ingested?(store, Store.digest(File.read!(@fixture)))
  end

  @tag :tmp_dir
  test "a reused file name with new contents is ingested, not skipped",
       %{store: store, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "run-sess-2.jsonl")

    File.cp!(@run_record_fixture, path)
    assert {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, path)

    File.cp!(@run_record_rma_terminal_fixture, path)
    assert {:ok, %{rows: %{"runs" => 1}}} = Session.ingest(store, path)

    assert {:ok, [["sess_fixture"], ["sess_rma_terminal"]]} =
             Store.query(store, "SELECT run_id FROM runs ORDER BY run_id")
  end

  @tag :tmp_dir
  test "the same contents under a new name are already ingested",
       %{store: store, tmp_dir: tmp_dir} do
    copy = Path.join(tmp_dir, "copy.jsonl")
    File.cp!(@run_record_fixture, copy)

    assert {:ok, _} = Session.ingest(store, @run_record_fixture)
    assert :already_ingested = Session.ingest(store, copy)
  end

  defp runs_row(store) do
    {:ok, columns} = Store.query(store, "SELECT column_name FROM (DESCRIBE runs)")
    {:ok, [row]} = Store.query(store, "SELECT * FROM runs")
    columns |> List.flatten() |> Enum.zip(row) |> Map.new()
  end
end
