defmodule MimirAnalytics.StoreTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row
  alias MimirAnalytics.Store

  setup do
    {:ok, store} = Store.open(:memory)
    %{store: store}
  end

  test "open applies schema", %{store: store} do
    {:ok, rows} = Store.query(store, "SELECT count(*) FROM runs")
    assert rows == [[0]]
  end

  test "ledger round-trip", %{store: store} do
    digest = Store.digest("contents\n")
    refute Store.ingested?(store, digest)
    :ok = Store.record_ingest(store, digest, "a.jsonl", "session", 3)
    assert Store.ingested?(store, digest)
  end

  test "the ledger matches by contents, not by name", %{store: store} do
    digest = Store.digest("contents\n")
    :ok = Store.record_ingest(store, digest, "a.jsonl", "session", 3)

    assert Store.ingested?(store, digest)
    refute Store.ingested?(store, Store.digest("other contents\n"))
  end

  test "insert writes Row structs and JSON-encodes nested values", %{store: store} do
    {:ok, 1} =
      Store.insert(store, "tool_calls", [
        %Row.ToolCall{
          run_id: "r1",
          turn: 1,
          seq: 1,
          tool_use_id: "tu_1",
          name: "search_kb",
          kind: "custom",
          input: %{"query" => "revenue"},
          source_file: "a.jsonl"
        }
      ])

    {:ok, [[name]]} = Store.query(store, "SELECT name FROM tool_calls WHERE run_id = 'r1'")
    assert name == "search_kb"
  end

  test "empty token refuses to attach (interactive-auth hang guard)" do
    System.put_env("MOTHERDUCK_TOKEN", "")
    on_exit(fn -> System.delete_env("MOTHERDUCK_TOKEN") end)

    assert_raise RuntimeError, ~r/MOTHERDUCK_TOKEN/, fn ->
      Store.open({:motherduck, "any_db"})
    end
  end

  describe "transaction/2" do
    test "commits and returns the function's :ok result on success", %{store: store} do
      row = %Row.ToolCall{
        run_id: "r1",
        turn: 1,
        seq: 1,
        tool_use_id: "tu_1",
        name: "search_kb",
        kind: "custom",
        input: %{},
        source_file: "a.jsonl"
      }

      assert {:ok, :done} =
               Store.transaction(store, fn s ->
                 {:ok, _} = Store.insert(s, "tool_calls", [row])
                 {:ok, :done}
               end)

      {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM tool_calls")
    end

    test "a failing batch (DB-level PK collision) leaves zero rows AND no ledger entry; re-run then succeeds cleanly",
         %{store: store} do
      good_row = %Row.ToolCall{
        run_id: "r1",
        turn: 1,
        seq: 1,
        tool_use_id: "tu_1",
        name: "search_kb",
        kind: "custom",
        input: %{},
        source_file: "crash.jsonl"
      }

      # Same (run_id, seq) as good_row — collides with tool_calls' composite
      # PK, so the DB itself rejects the second insert mid-batch.
      colliding_row = %{good_row | tool_use_id: "tu_2", name: "emit_narrative"}

      result =
        Store.transaction(store, fn s ->
          with {:ok, _n} <- Store.insert(s, "tool_calls", [good_row]) do
            Store.insert(s, "tool_calls", [colliding_row])
          end
        end)

      assert {:error, {:insert_failed, "tool_calls", _}} = result
      {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM tool_calls")
      refute Store.ingested?(store, "d1")

      # Re-run with only the good row now succeeds cleanly (proves the
      # rollback didn't leave the connection/transaction state wedged).
      assert {:ok, :recovered} =
               Store.transaction(store, fn s ->
                 {:ok, 1} = Store.insert(s, "tool_calls", [good_row])
                 :ok = Store.record_ingest(s, "d1", "crash.jsonl", "session", 1)
                 {:ok, :recovered}
               end)

      {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM tool_calls")
      assert Store.ingested?(store, "d1")
    end
  end
end
