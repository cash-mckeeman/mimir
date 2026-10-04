defmodule MimirAnalytics.SchemaTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers, Mappers.GatewayExport, Store}

  setup do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)
    {:ok, _} = Duckdbex.query(conn, "LOAD json")
    %{db: db, conn: conn}
  end

  test "apply/1 creates every canonical table, twice (idempotent)", %{conn: conn} do
    assert :ok = MimirAnalytics.Schema.apply(conn)
    assert :ok = MimirAnalytics.Schema.apply(conn)

    {:ok, ref} = Duckdbex.query(conn, "SELECT table_name FROM information_schema.tables")
    names = Duckdbex.fetch_all(ref) |> List.flatten() |> MapSet.new()

    for t <- MimirAnalytics.Schema.tables() do
      assert MapSet.member?(names, t), "missing table #{t}"
    end
  end

  test "correlation columns exist with canonical names", %{conn: conn} do
    :ok = MimirAnalytics.Schema.apply(conn)

    {:ok, ref} =
      Duckdbex.query(
        conn,
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'runs'"
      )

    cols = Duckdbex.fetch_all(ref) |> List.flatten() |> MapSet.new()

    for c <-
          ~w(run_id workflow_id step_id parent_step_id tenant_id agent_digest runtime cost_microdollars source_file) do
      assert MapSet.member?(cols, c), "runs missing column #{c}"
    end
  end

  test "apply/1 backfills columns onto a runs table created before they existed", %{
    conn: conn
  } do
    # The exact `runs` shape `priv/schema.sql` produced before `outcome` and
    # `error_class` were added — i.e. a real `.duckdb` file from before this
    # change, not a relaxed stand-in. `CREATE TABLE IF NOT EXISTS` alone is a
    # no-op against this table; `apply/1`'s `@column_migrations` ALTERs are
    # what have to reach it.
    {:ok, _} =
      Duckdbex.query(conn, """
      CREATE TABLE runs (
          run_id             TEXT PRIMARY KEY,
          workflow_id        TEXT,
          step_id            TEXT,
          parent_step_id     TEXT,
          tenant_id          TEXT,
          agent_digest       TEXT,
          agent_name         TEXT,
          agent_version      TEXT,
          runtime            TEXT,
          provider           TEXT,
          model              TEXT,
          lane               TEXT,
          terminal           TEXT,
          stop_reason        TEXT,
          turns              INTEGER,
          input_tokens       BIGINT,
          output_tokens      BIGINT,
          cost_microdollars  BIGINT,
          started_at         TIMESTAMP,
          finished_at        TIMESTAMP,
          source_file        TEXT NOT NULL
      )
      """)

    assert :ok = MimirAnalytics.Schema.apply(conn)

    {:ok, ref} =
      Duckdbex.query(
        conn,
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'runs'"
      )

    cols = Duckdbex.fetch_all(ref) |> List.flatten() |> MapSet.new()
    assert MapSet.member?(cols, "outcome")
    assert MapSet.member?(cols, "error_class")
  end

  test "a legacy database (runs table predating outcome) ingests a session fixture after apply/1",
       %{conn: conn} do
    {:ok, _} =
      Duckdbex.query(conn, """
      CREATE TABLE runs (
          run_id             TEXT PRIMARY KEY,
          workflow_id        TEXT,
          step_id            TEXT,
          parent_step_id     TEXT,
          tenant_id          TEXT,
          agent_digest       TEXT,
          agent_name         TEXT,
          agent_version      TEXT,
          runtime            TEXT,
          provider           TEXT,
          model              TEXT,
          lane               TEXT,
          terminal           TEXT,
          stop_reason        TEXT,
          turns              INTEGER,
          input_tokens       BIGINT,
          output_tokens      BIGINT,
          cost_microdollars  BIGINT,
          started_at         TIMESTAMP,
          finished_at        TIMESTAMP,
          source_file        TEXT NOT NULL
      )
      """)

    :ok = MimirAnalytics.Schema.apply(conn)

    store = %Store{conn: conn}

    fixture =
      Path.expand("../support/run_record_fixtures/session_local.jsonl", __DIR__)

    assert {:ok, %{rows: %{"runs" => 1}}} = Mappers.Session.ingest(store, fixture)
  end

  test "apply/1 backfills columns onto an events_raw table created before they existed", %{
    conn: conn
  } do
    # The exact `events_raw` shape `priv/schema.sql` produced before `domain`
    # and the three `ce_*` CloudEvents envelope columns were added — i.e. a
    # real `.duckdb` file from before those changes, not a relaxed stand-in.
    # `CREATE TABLE IF NOT EXISTS` alone is a no-op against this table;
    # `apply/1`'s `@column_migrations` ALTERs are what have to reach it.
    {:ok, _} =
      Duckdbex.query(conn, """
      CREATE TABLE events_raw (
          scope_id           TEXT,
          seq                BIGINT,
          ts                 TIMESTAMP,
          type               TEXT,
          payload            JSON,
          source             TEXT,
          source_file        TEXT NOT NULL
      )
      """)

    assert :ok = MimirAnalytics.Schema.apply(conn)

    {:ok, ref} =
      Duckdbex.query(
        conn,
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'events_raw'"
      )

    cols = Duckdbex.fetch_all(ref) |> List.flatten() |> MapSet.new()
    assert MapSet.member?(cols, "domain")
    assert MapSet.member?(cols, "ce_id")
    assert MapSet.member?(cols, "ce_source")
    assert MapSet.member?(cols, "ce_type")
  end

  test "a legacy database (events_raw table predating domain/ce_*) ingests a gateway-export fixture after apply/1",
       %{db: db, conn: conn} do
    {:ok, _} =
      Duckdbex.query(conn, """
      CREATE TABLE events_raw (
          scope_id           TEXT,
          seq                BIGINT,
          ts                 TIMESTAMP,
          type               TEXT,
          payload            JSON,
          source             TEXT,
          source_file        TEXT NOT NULL
      )
      """)

    :ok = MimirAnalytics.Schema.apply(conn)

    store = %Store{db: db, conn: conn}

    fixture =
      Path.expand("../support/run_record_fixtures/gateway_export.jsonl", __DIR__)

    assert {:ok, %{rows: %{"events_raw" => n}}} = GatewayExport.ingest(store, fixture)
    assert n > 0
  end

  test "apply/1 refuses a database whose ingest ledger is keyed by file name", %{conn: conn} do
    {:ok, _} =
      Duckdbex.query(conn, """
      CREATE TABLE ingest_ledger (
          source_file        TEXT PRIMARY KEY,
          source             TEXT NOT NULL,
          ingested_at        TIMESTAMP NOT NULL,
          rows               INTEGER NOT NULL
      )
      """)

    assert {:error, :name_keyed_ledger} = MimirAnalytics.Schema.apply(conn)

    {:ok, ref} = Duckdbex.query(conn, "SELECT table_name FROM information_schema.tables")
    assert Duckdbex.fetch_all(ref) == [["ingest_ledger"]]
  end
end
