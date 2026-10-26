defmodule MimirAnalytics.AccountingAuditsUpgradeTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{Event, Page, Source}
  alias MimirAnalytics.{AccountingStore, Schema, Store}

  defp execute(conn, path) do
    for statement <- path |> File.read!() |> String.split(";", trim: true),
        String.trim(statement) != "",
        do: assert({:ok, _} = Duckdbex.query(conn, statement))
  end

  defp snapshot(store) do
    for table <- ~w(accounting_events accounting_states gateway_checkpoints ingest_ledger),
        into: %{} do
      {:ok, values} = Store.query(store, "SELECT * FROM #{table} ORDER BY ALL")
      {table, values}
    end
  end

  defp fixture(conn) do
    assert {:ok, _} = Duckdbex.query(conn, "LOAD json")
    assert {:ok, _} = Duckdbex.query(conn, "LOAD core_functions")
    execute(conn, "test/support/accounting/pre_audit/schema.sql")
    execute(conn, "test/support/accounting/pre_audit/views.sql")
    {:ok, source} = Source.new(%{source_id: "test:retained", api_version: 2})
    wire = "test/support/accounting/producer.json" |> File.read!() |> Jason.decode!()
    {:ok, page} = Page.new(wire, source, nil)
    {:ok, page} = Page.from_buffer(Page.to_buffer(page), "retained.jsonl")
    store = %Store{conn: conn}

    for event <- page.events do
      assert {:ok, _} =
               Store.query(store, "INSERT INTO accounting_events VALUES (?, ?, ?, ?, ?, ?, ?)", [
                 event.source_id,
                 event.event_id,
                 event.virtual_key_id,
                 event.run_id,
                 event.booking_version,
                 Event.fingerprint(event),
                 Jason.encode!(Event.to_wire(event))
               ])
    end

    latest = Enum.at(page.events, 2)

    assert {:ok, _} =
             Store.query(
               store,
               "INSERT INTO accounting_states VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
               [
                 source.source_id,
                 latest.virtual_key_id,
                 latest.run_id,
                 latest.budget_period_start,
                 Jason.encode!(Event.to_wire(latest)),
                 "[]",
                 70,
                 "priced",
                 "settled"
               ]
             )

    assert {:ok, _} =
             Store.query(
               store,
               "INSERT INTO gateway_checkpoints VALUES (?, 2, 'accounting', ?, ?)",
               [source.source_id, page.next_cursor, page.digest]
             )

    assert {:ok, _} =
             Store.query(
               store,
               "INSERT INTO ingest_ledger VALUES (?, 'retained.jsonl', 'gateway_accounting', TIMESTAMP '2026-10-26 10:00:00', 5)",
               [page.digest]
             )

    {page, source}
  end

  @tag :tmp_dir
  test "immutable pre-audit file upgrades twice backfills and reopens without changing history",
       %{tmp_dir: dir} do
    path = Path.join(dir, "retained.duckdb")
    {:ok, db} = Duckdbex.open(path)
    {:ok, conn} = Duckdbex.connection(db)
    {page, source} = fixture(conn)
    original = snapshot(%Store{conn: conn})
    :ok = Duckdbex.release(conn)
    :ok = Duckdbex.release(db)
    {:ok, store} = Store.open(path)

    try do
      assert :ok = Schema.apply(store.conn)
      assert snapshot(store) == original
      assert {:ok, [[5]]} = Store.query(store, "SELECT count(*) FROM accounting_event_ids")
      assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_audits")
      assert :already_ingested = AccountingStore.ingest_page(store, page, :replay)

      repartition = %{
        page
        | digest: Store.digest("repartition"),
          source_file: "repartition.jsonl",
          events: Enum.reverse(page.events)
      }

      assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
               AccountingStore.ingest_page(store, repartition, :replay)

      assert {:ok, %{cursor: cursor, page_digest: digest}} =
               AccountingStore.checkpoint(store, source)

      assert {cursor, digest} == {page.next_cursor, page.digest}
    after
      Store.close(store)
    end

    {:ok, reopened} = Store.open(path)

    try do
      assert {:ok, [[5]]} = Store.query(reopened, "SELECT count(*) FROM accounting_event_ids")
      assert :already_ingested = AccountingStore.ingest_page(reopened, page, :replay)

      assert {:ok, %{booked_total_microdollars: 70}} =
               AccountingStore.get_state(
                 reopened,
                 source.source_id,
                 hd(page.events).virtual_key_id,
                 hd(page.events).run_id
               )
    after
      Store.close(reopened)
    end
  end

  test "retained registry mismatch refuses upgrade without overwriting history" do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)

    try do
      {page, _source} = fixture(conn)
      store = %Store{conn: conn}
      original = snapshot(store)

      assert {:ok, _} =
               Store.query(
                 store,
                 "CREATE TABLE accounting_event_ids (source_id TEXT, event_id TEXT, kind TEXT, fingerprint TEXT, PRIMARY KEY(source_id,event_id))"
               )

      event = hd(page.events)

      for {kind, fingerprint} <- [{"routing", Event.fingerprint(event)}, {"initial", "mismatch"}] do
        assert {:ok, _} = Store.query(store, "DELETE FROM accounting_event_ids")

        assert {:ok, _} =
                 Store.query(store, "INSERT INTO accounting_event_ids VALUES (?, ?, ?, ?)", [
                   event.source_id,
                   event.event_id,
                   kind,
                   fingerprint
                 ])

        assert {:error, :accounting_identity_conflict} = Schema.apply(conn)
        assert snapshot(store) == original

        assert {:ok, [[^kind, ^fingerprint]]} =
                 Store.query(store, "SELECT kind,fingerprint FROM accounting_event_ids")
      end
    after
      Duckdbex.release(conn)
      Duckdbex.release(db)
    end
  end
end
