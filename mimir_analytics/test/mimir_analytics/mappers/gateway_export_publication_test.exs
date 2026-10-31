defmodule MimirAnalytics.Mappers.GatewayExportPublicationTest do
  use ExUnit.Case, async: false

  alias MimirAnalytics.Accounting.{Error, Page, Source}
  alias MimirAnalytics.{AccountingStore, Mappers.GatewayExport, Store}
  alias MimirAnalytics.Ingest.GatewayAccountingBuffer
  alias Mix.Tasks.MimirAnalytics.Ingest

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "reader-published-buffer-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp source do
    {:ok, source} = Source.new(%{source_id: "test:published-buffer", api_version: 2})
    source
  end

  defp page do
    wire = "test/support/accounting/audits/mixed.json" |> File.read!() |> Jason.decode!()
    {:ok, page} = Page.new(wire, source(), nil)
    page
  end

  defp seed_checkpoint(store) do
    {:ok, empty} =
      Page.new(
        %{"api_version" => 2, "rows" => [], "limit" => 500, "next_cursor" => "seed"},
        source(),
        nil
      )

    {:ok, receipt} = Page.from_buffer(Page.to_buffer(empty), "seed.jsonl")
    {:ok, absent} = AccountingStore.checkpoint(store, source())
    assert {:ok, _} = AccountingStore.ingest_page(store, receipt, {:advance, absent})
    {:ok, checkpoint} = AccountingStore.checkpoint(store, source())
    assert checkpoint.cursor == "seed"
    {receipt.digest, checkpoint}
  end

  defp truncate_published(dir) do
    assert {:ok, receipt, path} = GatewayAccountingBuffer.publish(page(), dir)
    bytes = File.read!(path)
    assert {offset, _} = :binary.match(bytes, "\"accounting_page\"")
    truncated = binary_part(bytes, 0, offset)
    refute String.contains?(truncated, "\"accounting_page\"")
    assert {:error, _} = Jason.decode(truncated)
    File.write!(path, truncated)
    {path, bytes, truncated, receipt.digest}
  end

  defp snapshot(store) do
    Map.new(AccountingStore.tables() ++ ["ingest_ledger"], fn table ->
      assert {:ok, rows} = Store.query(store, "SELECT * FROM #{table} ORDER BY ALL")
      {table, rows}
    end)
  end

  test "truncated published bytes fail closed without changing durable accounting", %{dir: dir} do
    {:ok, store} = Store.open(:memory)

    try do
      {_seed_digest, checkpoint} = seed_checkpoint(store)
      before = snapshot(store)
      {path, bytes, truncated, published_digest} = truncate_published(dir)

      assert {:error, %Error{code: :invalid_page, field: nil, http_status: nil}} =
               GatewayExport.ingest(store, path)

      assert snapshot(store) == before
      assert {:ok, ^checkpoint} = AccountingStore.checkpoint(store, source())
      refute Store.ingested?(store, Store.digest(truncated))
      refute Store.ingested?(store, published_digest)
      custom = Path.join(dir, "complete-custom.jsonl")
      File.write!(custom, bytes)

      assert {:ok,
              %{
                rows: %{
                  "accounting_events" => 3,
                  "accounting_audits" => 6,
                  "accounting_states" => 1
                }
              }} = GatewayExport.ingest(store, custom)

      assert :already_ingested = GatewayExport.ingest(store, custom)
      assert {:ok, ^checkpoint} = AccountingStore.checkpoint(store, source())
      assert File.read!(path) == truncated
    after
      Store.close(store)
    end
  end

  test "CLI reports a truncated published file and continues to a later complete custom file", %{
    dir: dir
  } do
    db = Path.join(dir, "reader.duckdb")
    {:ok, store} = Store.open(db)

    {seed_digest, checkpoint, original_seed} =
      try do
        {digest, checkpoint} = seed_checkpoint(store)
        {:ok, rows} = Store.query(store, "SELECT * FROM ingest_ledger WHERE digest = ?", [digest])
        {digest, checkpoint, rows}
      after
        Store.close(store)
      end

    gateway = Path.join(dir, "gateway")
    {bad, bytes, truncated, published_digest} = truncate_published(gateway)
    good = Path.join(gateway, "zz-valid-custom.jsonl")
    File.write!(good, bytes)
    assert Path.wildcard(Path.join(gateway, "*.jsonl")) == [bad, good]
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Ingest.run(["--db", db, "--gateway", gateway])
      assert_received {:mix_shell, :error, [message]}
      assert message =~ Path.basename(bad)
      assert message =~ "invalid_page"
      refute message =~ "Jason.DecodeError"
      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ "gateway: 1"
    after
      Mix.shell(old_shell)
    end

    {:ok, reopened} = Store.open(db)

    try do
      assert {:ok, ^checkpoint} = AccountingStore.checkpoint(reopened, source())

      assert {:ok, ^original_seed} =
               Store.query(reopened, "SELECT * FROM ingest_ledger WHERE digest = ?", [seed_digest])

      assert {:ok, [[2]]} = Store.query(reopened, "SELECT count(*) FROM ingest_ledger")

      assert {:ok, [["zz-valid-custom.jsonl", 9]]} =
               Store.query(
                 reopened,
                 "SELECT source_file,rows FROM ingest_ledger WHERE digest = ?",
                 [published_digest]
               )

      assert {:ok, [[3]]} = Store.query(reopened, "SELECT count(*) FROM accounting_events")
      assert {:ok, [[6]]} = Store.query(reopened, "SELECT count(*) FROM accounting_audits")
      assert {:ok, [[9]]} = Store.query(reopened, "SELECT count(*) FROM accounting_event_ids")
      assert {:ok, [[1]]} = Store.query(reopened, "SELECT count(*) FROM accounting_states")
      refute Store.ingested?(reopened, Store.digest(truncated))
      assert File.read!(bad) == truncated
      assert File.read!(good) == bytes
    after
      Store.close(reopened)
    end
  end

  test "malformed legacy and nonpublisher lookalike names keep their JSON exception", %{dir: dir} do
    {:ok, store} = Store.open(:memory)

    try do
      for name <- [
            "legacy.jsonl",
            "gateway_accounting-not-a-digest.jsonl",
            "gateway_accounting-#{String.duplicate("A", 64)}.jsonl"
          ] do
        path = Path.join(dir, name)
        File.write!(path, "{not json\n")
        assert_raise Jason.DecodeError, fn -> GatewayExport.ingest(store, path) end
      end

      assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
    after
      Store.close(store)
    end
  end
end
