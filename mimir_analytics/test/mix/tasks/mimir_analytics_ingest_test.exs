defmodule Mix.Tasks.MimirAnalytics.IngestTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.MimirAnalytics.Ingest

  @fx Path.expand("../../support/run_record_fixtures", __DIR__)

  @tag :tmp_dir
  test "end-to-end ingest builds a queryable db", %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")

    for {sub, file} <- [
          {"sessions", "session_local.jsonl"},
          {"gateway", "gateway_export.jsonl"},
          {"evals", "eval_report.json"}
        ] do
      File.mkdir_p!(Path.join(dir, sub))
      File.cp!(Path.join(@fx, file), Path.join([dir, sub, file]))
    end

    Ingest.run([
      "--db",
      db,
      "--sessions",
      Path.join(dir, "sessions"),
      "--gateway",
      Path.join(dir, "gateway"),
      "--evals",
      Path.join(dir, "evals")
    ])

    {:ok, store} = MimirAnalytics.Store.open(db)
    {:ok, [[c]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM v_parity_cost")
    assert c >= 1
  end

  describe "archiving after a successful ingest" do
    setup %{tmp_dir: dir} do
      for {sub, file} <- [
            {"sessions", "session_local.jsonl"},
            {"gateway", "gateway_export.jsonl"},
            {"evals", "eval_report.json"}
          ] do
        File.mkdir_p!(Path.join(dir, sub))
        File.cp!(Path.join(@fx, file), Path.join([dir, sub, file]))
      end

      Ingest.run([
        "--db",
        Path.join(dir, "rr.duckdb"),
        "--sessions",
        Path.join(dir, "sessions"),
        "--gateway",
        Path.join(dir, "gateway"),
        "--evals",
        Path.join(dir, "evals")
      ])

      :ok
    end

    @tag :tmp_dir
    test "moves a sessions file into .ingested/", %{tmp_dir: dir} do
      refute File.exists?(Path.join([dir, "sessions", "session_local.jsonl"]))
      assert File.exists?(Path.join([dir, "sessions", ".ingested", "session_local.jsonl"]))
    end

    @tag :tmp_dir
    test "leaves a gateway file in place", %{tmp_dir: dir} do
      assert File.exists?(Path.join([dir, "gateway", "gateway_export.jsonl"]))
      refute File.exists?(Path.join([dir, "gateway", ".ingested"]))
    end

    @tag :tmp_dir
    test "leaves an eval report in place", %{tmp_dir: dir} do
      assert File.exists?(Path.join([dir, "evals", "eval_report.json"]))
      refute File.exists?(Path.join([dir, "evals", ".ingested"]))
    end
  end

  @tag :tmp_dir
  test "an ingested file moves aside into .ingested/, and a re-run neither re-ingests it nor re-reads the archive",
       %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    File.cp!(Path.join(@fx, "session_local.jsonl"), Path.join(sessions, "session_local.jsonl"))

    argv = ["--db", db, "--sessions", sessions]

    Ingest.run(argv)

    refute File.exists?(Path.join(sessions, "session_local.jsonl"))
    assert File.exists?(Path.join([sessions, ".ingested", "session_local.jsonl"]))

    {:ok, store} = MimirAnalytics.Store.open(db)
    {:ok, [[before_count]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM runs")

    # Plant a file directly inside `.ingested/`, under a basename the ledger
    # has never seen. `session_local.jsonl` alone would pass the count
    # assertion below on ledger dedup alone (it's already `ingested?`), which
    # wouldn't prove the glob itself skips `.ingested/`. This file's run_id
    # is not in the ledger — if the glob recursed into `.ingested/`, it would
    # get ingested and its row would appear.
    planted = Path.join([sessions, ".ingested", "never_ingested.jsonl"])
    File.cp!(Path.join(@fx, "session_legacy_run_id_fallback.jsonl"), planted)

    Ingest.run(argv)

    {:ok, [[after_count]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM runs")
    assert after_count == before_count
    assert File.exists?(Path.join([sessions, ".ingested", "session_local.jsonl"]))
    assert File.exists?(planted)

    {:ok, rows} =
      MimirAnalytics.Store.query(
        store,
        "SELECT run_id FROM runs WHERE run_id = 'sess_legacy_001'"
      )

    assert rows == []
  end

  @tag :tmp_dir
  test "archiving never overwrites an older archived file with the same name", %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    archive = Path.join(sessions, ".ingested")
    File.mkdir_p!(archive)
    File.write!(Path.join(archive, "session_local.jsonl"), "older\n")
    File.cp!(Path.join(@fx, "session_local.jsonl"), Path.join(sessions, "session_local.jsonl"))

    Ingest.run(["--db", Path.join(dir, "rr.duckdb"), "--sessions", sessions])

    refute File.exists?(Path.join(sessions, "session_local.jsonl"))
    assert File.read!(Path.join(archive, "session_local.jsonl")) == "older\n"

    assert File.read!(Path.join(archive, "session_local.1.jsonl")) ==
             File.read!(Path.join(@fx, "session_local.jsonl"))
  end

  # The temporary name a producer writes before publishing by rename:
  # dot-prefixed, `.tmp`-suffixed, a sibling of the final file.
  @tag :tmp_dir
  test "an unpublished temporary file in the spool is neither ingested nor archived",
       %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    tmp = Path.join(sessions, ".run-sess_fixture-7.jsonl.tmp")
    File.cp!(Path.join(@fx, "run_record.jsonl"), tmp)

    Ingest.run(["--db", db, "--sessions", sessions])

    assert File.exists?(tmp)
    refute File.exists?(Path.join(sessions, ".ingested"))

    {:ok, store} = MimirAnalytics.Store.open(db)
    assert {:ok, [[0]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM runs")
    assert {:ok, [[0]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM ingest_ledger")
  end

  @tag :tmp_dir
  test "two spool files published in sequence under one name are both ingested",
       %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    name = Path.join(sessions, "run-sess-2.jsonl")

    File.cp!(Path.join(@fx, "run_record.jsonl"), name)
    Ingest.run(["--db", db, "--sessions", sessions])
    File.cp!(Path.join(@fx, "run_record_rma_terminal.jsonl"), name)
    Ingest.run(["--db", db, "--sessions", sessions])

    {:ok, store} = MimirAnalytics.Store.open(db)

    assert {:ok, [["sess_fixture"], ["sess_rma_terminal"]]} =
             MimirAnalytics.Store.query(store, "SELECT run_id FROM runs ORDER BY run_id")

    refute File.exists?(name)
  end

  # The spool's invariant under concurrency: a producer that publishes by
  # rename can keep writing while ingest reads and archives, and once it stops,
  # one more run has ingested every record it wrote.
  @tag :tmp_dir
  test "every record written while ingest runs is ingested", %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    argv = ["--db", db, "--sessions", sessions]

    write = fn i ->
      MimirAnalytics.Capture.write(%{"session_id" => "s#{i}"}, %{"workflow_id" => "wf"}, sessions)
    end

    for i <- 1..100, do: write.(i)

    # At most 400 records, so a slow run cannot let the producer outpace the
    # test.
    producer =
      Task.async(fn ->
        Enum.reduce_while(101..400, 100, fn i, _ ->
          write.(i)

          receive do
            :stop -> {:halt, i}
          after
            1 -> {:cont, i}
          end
        end)
      end)

    for _ <- 1..3, do: Ingest.run(argv)
    send(producer.pid, :stop)
    written = Task.await(producer)
    Ingest.run(argv)

    {:ok, store} = MimirAnalytics.Store.open(db)
    assert {:ok, [[^written]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM runs")
    assert Path.wildcard(Path.join(sessions, "*.jsonl")) == []
  end

  # A database from before the ledger was keyed by content holds name-keyed
  # entries, such as one for a daily file the old append writer kept growing
  # after it was read. Such a database is refused, not silently trusted, and
  # the documented rebuild (delete it, re-ingest the sources) reads the grown
  # file once, in full.
  @tag :tmp_dir
  test "a name-keyed ledger with a grown daily file is refused, and a rebuild reads the whole file once",
       %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    daily = Path.join(sessions, "sessions-2026-08-01.jsonl")

    {:ok, legacy} = Duckdbex.open(db)
    {:ok, conn} = Duckdbex.connection(legacy)

    for stmt <- [
          """
          CREATE TABLE ingest_ledger (source_file TEXT PRIMARY KEY, source TEXT NOT NULL,
                                      ingested_at TIMESTAMP NOT NULL, rows INTEGER NOT NULL)
          """,
          "INSERT INTO ingest_ledger VALUES ('sessions-2026-08-01.jsonl', 'session', TIMESTAMP '2026-08-01 00:00:00', 1)"
        ] do
      {:ok, _} = Duckdbex.query(conn, stmt)
    end

    :ok = Duckdbex.release(conn)
    :ok = Duckdbex.release(legacy)

    line = fn i ->
      Jason.encode!(%{"meta" => %{"workflow_id" => "wf"}, "result" => %{"session_id" => "s#{i}"}})
    end

    File.write!(daily, line.(1) <> "\n" <> line.(2) <> "\n")
    argv = ["--db", db, "--sessions", sessions]

    in_own_process(fn ->
      assert_raise Mix.Error, ~r/keyed by file name/, fn -> Ingest.run(argv) end
    end)

    assert File.exists?(daily)

    File.rm!(db)
    in_own_process(fn -> Ingest.run(argv) end)
    in_own_process(fn -> Ingest.run(argv) end)

    {:ok, store} = MimirAnalytics.Store.open(db)

    assert {:ok, [["s1"], ["s2"]]} =
             MimirAnalytics.Store.query(store, "SELECT run_id FROM runs ORDER BY run_id")

    refute File.exists?(daily)
  end

  @tag :tmp_dir
  test "a spool file with contents already ingested is reported and moved aside",
       %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    File.cp!(Path.join(@fx, "run_record.jsonl"), Path.join(sessions, "a.jsonl"))
    File.cp!(Path.join(@fx, "run_record.jsonl"), Path.join(sessions, "b.jsonl"))

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Ingest.run(["--db", Path.join(dir, "rr.duckdb"), "--sessions", sessions])

    assert Path.wildcard(Path.join(sessions, "*.jsonl")) == []

    assert ~w(a.jsonl b.jsonl) ==
             sessions |> Path.join(".ingested") |> File.ls!() |> Enum.sort()

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "b.jsonl has contents already ingested"
  end

  @tag :tmp_dir
  test "an empty spool file is reported and quarantined, not ledgered", %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    empty = Path.join(sessions, "run-a-1.jsonl")
    File.write!(empty, "")

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Ingest.run(["--db", db, "--sessions", sessions])

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "run-a-1.jsonl"
    assert message =~ "empty_file"
    refute File.exists?(empty)
    assert File.exists?(Path.join([sessions, ".quarantined", "run-a-1.jsonl"]))

    {:ok, store} = MimirAnalytics.Store.open(db)
    assert {:ok, [[0]]} = MimirAnalytics.Store.query(store, "SELECT count(*) FROM ingest_ledger")
  end

  @tag :tmp_dir
  test "an empty spool file is quarantined and a rewritten eval report stays in place, each reported once",
       %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    evals = Path.join(dir, "evals")
    File.mkdir_p!(sessions)
    File.mkdir_p!(evals)
    original = File.read!(Path.join(@fx, "eval_report.json"))
    report = Path.join(evals, "eval_report.json")
    File.write!(report, original)
    argv = ["--db", db, "--sessions", sessions, "--evals", evals]

    in_own_process(fn -> Ingest.run(argv) end)

    File.write!(report, original <> "\n")
    File.write!(Path.join(sessions, "run-a-1.jsonl"), "")

    # Mix.Shell.Process delivers to the test process, the run's caller.
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    in_own_process(fn -> Ingest.run(argv) end)
    in_own_process(fn -> Ingest.run(argv) end)
    errors = collect_shell_errors([])

    assert [_] = Enum.filter(errors, &(&1 =~ "run-a-1.jsonl"))
    assert [_] = Enum.filter(errors, &(&1 =~ "eval_report.json"))

    refute File.exists?(Path.join(sessions, "run-a-1.jsonl"))
    assert File.exists?(Path.join([sessions, ".quarantined", "run-a-1.jsonl"]))
    assert File.exists?(Path.join([sessions, ".quarantined", "run-a-1.jsonl.reason"]))

    assert File.read!(report) == original <> "\n"
    refute File.exists?(Path.join(evals, ".quarantined"))

    # A further rewrite is new contents, so it is reported again, once.
    File.write!(report, original <> "\n\n")
    in_own_process(fn -> Ingest.run(argv) end)
    in_own_process(fn -> Ingest.run(argv) end)
    assert [_] = Enum.filter(collect_shell_errors([]), &(&1 =~ "eval_report.json"))
    assert File.exists?(report)
  end

  # A run that raises must still close its database, or a later run on the
  # same file overlaps the leaked instance's eventual close. The run happens in
  # a process that then waits without allocating, so its garbage is not
  # collected and only an explicit close can release the file.
  @tag :tmp_dir
  test "a run that raises still closes the database", %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    File.write!(Path.join(sessions, "malformed.jsonl"), "{not json\n")
    test = self()

    runner =
      spawn(fn ->
        result =
          try do
            Ingest.run(["--db", db, "--sessions", sessions])
          rescue
            e in Jason.DecodeError -> {:raised, e}
          end

        send(test, {:ran, result})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:ran, {:raised, %Jason.DecodeError{}}}, 30_000
    refute db in open_files()
    send(runner, :done)
  end

  @tag :tmp_dir
  test "a file that fails ingest is left in place, not archived", %{tmp_dir: dir} do
    db = Path.join(dir, "rr.duckdb")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)

    File.cp!(
      Path.join(@fx, "session_duplicate_run_id.jsonl"),
      Path.join(sessions, "crash.jsonl")
    )

    Ingest.run(["--db", db, "--sessions", sessions])

    assert File.exists?(Path.join(sessions, "crash.jsonl"))
    refute File.exists?(Path.join([sessions, ".ingested", "crash.jsonl"]))
  end

  @tag :tmp_dir
  test "a file that fails ingest is reported with its reason", %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    crash = Path.join(sessions, "crash.jsonl")
    File.cp!(Path.join(@fx, "session_duplicate_run_id.jsonl"), crash)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Ingest.run(["--db", Path.join(dir, "rr.duckdb"), "--sessions", sessions])

    assert_received {:mix_shell, :error, [message]}
    assert message =~ crash
    assert message =~ "insert_failed"
  end

  # One DuckDB instance per database file at a time: each run's handle is
  # released when its process exits.
  defp in_own_process(fun), do: fun |> Task.async() |> Task.await(:infinity)

  defp collect_shell_errors(acc) do
    receive do
      {:mix_shell, :error, [message]} -> collect_shell_errors([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Paths this VM holds open: /proc on Linux, lsof elsewhere.
  defp open_files do
    if File.dir?("/proc/self/fd") do
      for fd <- Path.wildcard("/proc/self/fd/*"),
          {:ok, target} <- [File.read_link(fd)],
          do: target
    else
      {out, 0} = System.cmd("lsof", ["-p", System.pid(), "-Fn"])
      for "n" <> path <- String.split(out, "\n"), do: path
    end
  end
end
