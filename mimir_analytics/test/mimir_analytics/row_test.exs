defmodule MimirAnalytics.RowTest do
  use ExUnit.Case, async: true

  @moduledoc false

  setup do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)
    :ok = MimirAnalytics.Schema.apply(conn)
    %{conn: conn}
  end

  test "each canonical and actual main table has exactly one write owner", %{conn: conn} do
    direct = MapSet.new(Map.keys(MimirAnalytics.Row.tables()))
    store = MapSet.new(~w(ingest_ledger ingest_rejections))
    accounting = MapSet.new(~w(accounting_events accounting_states gateway_checkpoints))
    assert MapSet.disjoint?(direct, store)
    assert MapSet.disjoint?(direct, accounting)
    assert MapSet.disjoint?(store, accounting)
    owned = direct |> MapSet.union(store) |> MapSet.union(accounting)
    assert owned == MapSet.new(MimirAnalytics.Schema.tables())

    {:ok, result} =
      Duckdbex.query(conn, """
      SELECT table_name FROM information_schema.tables
      WHERE table_catalog = current_database() AND table_schema = 'main' AND table_type = 'BASE TABLE'
      """)

    assert owned == result |> Duckdbex.fetch_all() |> List.flatten() |> MapSet.new()
  end

  test "every Row struct's fields are exactly its table's real columns", %{conn: conn} do
    for {table, mod} <- MimirAnalytics.Row.tables() do
      table_cols = table_columns(conn, table)

      struct_fields =
        mod
        |> struct()
        |> Map.from_struct()
        |> Map.keys()
        |> MapSet.new(&Atom.to_string/1)

      missing_from_struct = MapSet.difference(table_cols, struct_fields)
      extra_on_struct = MapSet.difference(struct_fields, table_cols)

      assert MapSet.size(missing_from_struct) == 0,
             "#{inspect(mod)} is missing fields for #{table} columns: #{inspect(missing_from_struct)}"

      assert MapSet.size(extra_on_struct) == 0,
             "#{inspect(mod)} has fields with no matching #{table} column: #{inspect(extra_on_struct)}"
    end
  end

  defp table_columns(conn, table) do
    {:ok, ref} =
      Duckdbex.query(
        conn,
        "SELECT column_name FROM information_schema.columns WHERE table_name = '#{table}'"
      )

    ref |> Duckdbex.fetch_all() |> List.flatten() |> MapSet.new()
  end
end
