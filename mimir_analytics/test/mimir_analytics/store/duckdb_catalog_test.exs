defmodule MimirAnalytics.Store.DuckDBCatalogTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Accounting.{Page, Source}
  alias MimirAnalytics.{AccountingStore, Schema, Store}
  alias MimirAnalytics.Store.DuckDB

  setup do
    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    %{store: store}
  end

  defp selected(store) do
    assert {:ok, _} = Store.query(store, "ATTACH ':memory:' AS selected")
    assert {:ok, _} = Store.query(store, "USE selected")
    assert :ok = Schema.apply(store.conn)
  end

  defp source do
    {:ok, source} = Source.new(%{source_id: "test:namespace", api_version: 2})
    source
  end

  defp rows do
    "test/support/accounting/audits/mixed.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("rows")
  end

  defp page(rows, cursor) do
    {:ok, page} =
      Page.new(
        %{"api_version" => 2, "rows" => rows, "next_cursor" => cursor, "limit" => 500},
        source(),
        nil
      )

    {:ok, receipt} = Page.from_buffer(Page.to_buffer(page), "namespace.jsonl")
    receipt
  end

  defp assert_namespace(store, expected) do
    assert {:ok, lease} = DuckDB.lease(store, nil)

    try do
      assert lease.conn != store.conn
      assert lease.db == store.db

      assert {:ok, [^expected]} =
               Store.query(lease, "SELECT current_database(), current_schema()")
    after
      DuckDB.release(lease, nil)
    end

    assert {:ok, [^expected]} = Store.query(store, "SELECT current_database(), current_schema()")
  end

  defp snapshot(store, namespace) do
    Map.new(
      ~w(accounting_events accounting_audits accounting_event_ids accounting_states gateway_checkpoints ingest_ledger),
      fn table ->
        assert {:ok, rows} =
                 Store.query(store, "SELECT * FROM #{namespace}.#{table} ORDER BY ALL")

        {table, rows}
      end
    )
  end

  defp close_if_leased({:ok, lease}), do: DuckDB.release(lease, nil)
  defp close_if_leased({:error, :unavailable}), do: :ok

  test "fresh lease preserves an attached catalog with valid default accounting tables", %{
    store: store
  } do
    selected(store)
    assert_namespace(store, ["selected", "main"])
  end

  test "fresh lease preserves a nondefault schema in the original catalog", %{store: store} do
    assert {:ok, _} = Store.query(store, "CREATE SCHEMA nondefault")
    assert {:ok, _} = Store.query(store, "USE memory.nondefault")
    assert :ok = Schema.apply(store.conn)
    assert_namespace(store, ["memory", "nondefault"])
  end

  test "catalog and schema identifiers retain embedded quotes and dots", %{store: store} do
    assert {:ok, _} = Store.query(store, ~s(ATTACH ':memory:' AS "selected""catalog.dot"))

    assert {:ok, _} =
             Store.query(store, ~s(CREATE SCHEMA "selected""catalog.dot"."non""default.schema"))

    assert {:ok, _} = Store.query(store, ~s(USE "selected""catalog.dot"."non""default.schema"))
    assert :ok = Schema.apply(store.conn)
    assert_namespace(store, [~s(selected"catalog.dot), ~s(non"default.schema)])
  end

  test "checkpoint reads the selected catalog instead of a valid default checkpoint", %{
    store: store
  } do
    default_digest = String.duplicate("a", 64)
    selected_digest = String.duplicate("b", 64)

    assert {:ok, _} =
             Store.query(store, "INSERT INTO gateway_checkpoints VALUES (?,2,'accounting',?,?)", [
               source().source_id,
               "default",
               default_digest
             ])

    selected(store)

    assert {:ok, _} =
             Store.query(store, "INSERT INTO gateway_checkpoints VALUES (?,2,'accounting',?,?)", [
               source().source_id,
               "selected",
               selected_digest
             ])

    assert {:ok, %{cursor: "selected", page_digest: ^selected_digest}} =
             AccountingStore.checkpoint(store, source())

    assert {:ok, [["default", ^default_digest]]} =
             Store.query(store, "SELECT cursor,page_digest FROM memory.main.gateway_checkpoints")
  end

  test "replay advance registry and state stay in the selected namespace", %{store: store} do
    correction = Enum.find(rows(), &(&1["kind"] == "correction" and &1["booking_version"] == 3))
    {:ok, absent} = AccountingStore.checkpoint(store, source())

    assert {:ok, _} =
             AccountingStore.ingest_page(store, page([correction], "default"), {:advance, absent})

    original = snapshot(store, "memory.main")
    selected(store)
    receipt = page(rows(), "selected")

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 3,
                "accounting_audits" => 6,
                "accounting_states" => 1
              }
            }} = AccountingStore.ingest_page(store, receipt, :replay)

    assert :already_ingested = AccountingStore.ingest_page(store, receipt, :replay)

    assert {:ok, %{cursor: nil, page_digest: nil} = selected_absent} =
             AccountingStore.checkpoint(store, source())

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 0,
                "accounting_audits" => 0,
                "accounting_states" => 0
              }
            }} = AccountingStore.ingest_page(store, receipt, {:advance, selected_absent})

    assert {:ok, %{cursor: "selected", page_digest: digest}} =
             AccountingStore.checkpoint(store, source())

    assert digest == receipt.digest

    assert {:ok, %{history: :complete, booked_total_microdollars: 70}} =
             AccountingStore.get_state(
               store,
               source().source_id,
               correction["virtual_key_id"],
               correction["run_id"]
             )

    assert {:ok, [[3]]} =
             Store.query(store, "SELECT count(*) FROM selected.main.accounting_events")

    assert {:ok, [[6]]} =
             Store.query(store, "SELECT count(*) FROM selected.main.accounting_audits")

    assert {:ok, [[9]]} =
             Store.query(store, "SELECT count(*) FROM selected.main.accounting_event_ids")

    assert {:ok, [[1]]} =
             Store.query(store, "SELECT count(*) FROM selected.main.accounting_states")

    assert {:ok, [[digest, 9]]} =
             Store.query(store, "SELECT digest,rows FROM selected.main.ingest_ledger")

    assert digest == receipt.digest
    assert snapshot(store, "memory.main") == original

    assert {:ok, [[nil]]} =
             Store.query(
               store,
               "SELECT booked_total_microdollars FROM memory.main.accounting_states"
             )
  end

  test "selected schema leases preserve the caller open transaction snapshot", %{store: store} do
    selected(store)
    assert {:ok, _} = Store.query(store, "CREATE SCHEMA selected.nondefault")
    assert {:ok, _} = Store.query(store, "USE selected.nondefault")
    assert :ok = Schema.apply(store.conn)
    default = snapshot(store, "memory.main")
    assert {:ok, _} = Store.query(store, "BEGIN")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, _} = AccountingStore.ingest_page(store, page(rows(), "selected"), :replay)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, _} = Store.query(store, "ROLLBACK")

    assert {:ok, [[3]]} =
             Store.query(store, "SELECT count(*) FROM selected.nondefault.accounting_events")

    assert snapshot(store, "memory.main") == default
    assert_namespace(store, ["selected", "nondefault"])
  end

  test "failed context read never repairs the caller or falls back to default", %{store: store} do
    assert {:ok, _} = Store.query(store, "CREATE TABLE sentinel (id INTEGER PRIMARY KEY)")
    assert {:ok, _} = Store.query(store, "BEGIN")
    assert {:error, _} = Store.query(store, "INSERT INTO sentinel VALUES (1),(1)")
    result = DuckDB.lease(store, nil)

    try do
      assert {:error, :unavailable} = result
    after
      close_if_leased(result)
    end

    assert {:error, reason} = Store.query(store, "SELECT 1")
    assert reason =~ "Current transaction is aborted"
    assert {:ok, _} = Store.query(store, "ROLLBACK")
    assert_namespace(store, ["memory", "main"])
  end

  test "failed context copy never leases the default or changes caller transaction", %{
    store: store
  } do
    assert {:ok, _} = Store.query(store, "BEGIN")
    assert {:ok, _} = Store.query(store, "CREATE SCHEMA pending_namespace")
    assert {:ok, _} = Store.query(store, "USE memory.pending_namespace")

    assert {:ok, [["memory", "pending_namespace"]]} =
             Store.query(store, "SELECT current_database(),current_schema()")

    result = DuckDB.lease(store, nil)

    try do
      assert {:error, :unavailable} = result
    after
      close_if_leased(result)
    end

    assert {:ok, [[1]]} =
             Store.query(
               store,
               "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'pending_namespace'"
             )

    assert {:ok, _} = Store.query(store, "ROLLBACK")
    assert {:ok, _} = Store.query(store, "USE memory.main")

    assert {:ok, [[0]]} =
             Store.query(
               store,
               "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'pending_namespace'"
             )

    assert_namespace(store, ["memory", "main"])
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end
end
