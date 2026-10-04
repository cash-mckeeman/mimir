defmodule MimirAnalytics.RowTest do
  use ExUnit.Case, async: true

  @moduledoc false

  setup do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)
    :ok = MimirAnalytics.Schema.apply(conn)
    %{conn: conn}
  end

  test "Row.tables/0 covers every canonical table except the internally-managed ledgers" do
    assert MapSet.new(Map.keys(MimirAnalytics.Row.tables())) ==
             MimirAnalytics.Schema.tables()
             |> Enum.reject(&(&1 in ["ingest_ledger", "ingest_rejections"]))
             |> MapSet.new()
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
