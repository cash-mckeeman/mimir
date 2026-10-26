defmodule MimirAnalytics.Store.DuckDBTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Store
  alias MimirAnalytics.Store.DuckDB

  test "commit rejects an actually aborted transaction and healthy commits remain durable" do
    {:ok, store} = Store.open(:memory)

    try do
      {:ok, _} = Store.query(store, "CREATE TABLE sentinel (id INTEGER PRIMARY KEY)")
      {:ok, lease} = DuckDB.lease(store, nil)

      try do
        assert {:ok, _} = DuckDB.command(lease, :begin, nil)
        assert {:ok, _} = Store.query(lease, "INSERT INTO sentinel VALUES (71)")
        assert {:error, _} = Store.query(lease, "INSERT INTO sentinel VALUES (1), (1)")
        assert {:error, reason} = Store.query(lease, "SELECT 1")
        assert reason =~ "Current transaction is aborted"
        assert {:error, :conflict} = DuckDB.command(lease, :commit, nil)
        assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM sentinel")
        assert {:ok, _} = DuckDB.command(lease, :begin, nil)
        assert {:ok, _} = Store.query(lease, "INSERT INTO sentinel VALUES (42)")
        assert {:ok, _} = DuckDB.command(lease, :commit, nil)
        assert {:ok, [[42]]} = Store.query(store, "SELECT * FROM sentinel")
      after
        DuckDB.release(lease, nil)
      end
    after
      Store.close(store)
    end
  end
end
