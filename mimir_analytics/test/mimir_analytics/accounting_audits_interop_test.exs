defmodule MimirAnalytics.AuditLostAckDB do
  @moduledoc false
  @behaviour MimirAnalytics.Store.DB
  alias MimirAnalytics.Store
  alias MimirAnalytics.Store.{DB, DuckDB}
  @impl true
  @spec lease(Store.t(), pid()) :: {:ok, Store.t()} | {:error, :unavailable}
  def lease(store, _context), do: DuckDB.lease(store, nil)
  @impl true
  @spec release(Store.t(), pid()) :: :ok
  def release(store, _context), do: DuckDB.release(store, nil)
  @impl true
  @spec command(Store.t(), DB.command(), pid()) :: {:ok, [[term()]]} | {:error, DB.failure()}
  def command(store, command, context) do
    result = DuckDB.command(store, command, nil)

    if command == :commit and Agent.get_and_update(context, fn lost -> {not lost, true} end) do
      {:ok, _} = result
      {:error, :unavailable}
    else
      result
    end
  end
end

defmodule MimirAnalytics.AccountingAuditsInteropTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{Page, Source}
  alias MimirAnalytics.{AccountingStore, Store, Views}
  alias MimirAnalytics.Ingest.GatewayPull
  alias MimirAnalytics.Mappers.GatewayExport
  defp bytes(name), do: File.read!("test/support/accounting/audits/#{name}.json")
  defp wire(name), do: name |> bytes() |> Jason.decode!()

  defp source do
    {:ok, source} = Source.new(%{source_id: "test:audits-http", api_version: 2})
    source
  end

  defp opts(store, dir, extra \\ []) do
    Keyword.merge(
      [
        api_version: 2,
        source_id: source().source_id,
        store: store,
        dir: dir,
        base_url: "http://gateway.test",
        token: "synthetic-read-token",
        req_options: [plug: {Req.Test, GatewayPull}]
      ],
      extra
    )
  end

  defp response(conn, name, status \\ 200),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, bytes(name))

  defp snapshot(store) do
    assert :ok = Views.apply(store.conn)

    for table <-
          ~w(accounting_events accounting_audits accounting_event_ids accounting_states v_gateway_accounting_spend v_gateway_accounting_audits),
        into: %{} do
      {:ok, rows} = Store.query(store, "SELECT * FROM #{table} ORDER BY ALL")
      {table, rows}
    end
  end

  @tag :tmp_dir
  test "actual producer HTTP bytes survive pull retained buffers reconstruction and replay", %{
    tmp_dir: dir
  } do
    {:ok, store} = Store.open(:memory)
    {:ok, rebuilt} = Store.open(:memory)

    try do
      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        if conn.params["cursor"], do: response(conn, "empty"), else: response(conn, "mixed")
      end)

      assert {:ok, %{files: files, last_cursor: cursor}} = GatewayPull.pull(opts(store, dir))
      assert length(files) == 2
      assert cursor == "eyJ2IjoyLCJzZXF1ZW5jZSI6MzE1Nn0"

      assert {:ok, [[9], [0]]} =
               Store.query(store, "SELECT rows FROM ingest_ledger ORDER BY rows DESC")

      for path <- files do
        assert :already_ingested = GatewayExport.ingest(store, path)
        assert {:ok, _} = GatewayExport.ingest(rebuilt, path)
        assert :already_ingested = GatewayExport.ingest(rebuilt, path)
      end

      assert snapshot(store) == snapshot(rebuilt)

      assert {:ok, [[70]]} =
               Store.query(
                 rebuilt,
                 "SELECT booked_applied_total_microdollars FROM v_gateway_accounting_spend"
               )

      assert {:ok, [[3]]} = Store.query(rebuilt, "SELECT count(*) FROM accounting_events")
      assert {:ok, [[6]]} = Store.query(rebuilt, "SELECT count(*) FROM accounting_audits")
      assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(rebuilt, source())
      assert {:ok, %{cursor: ^cursor}} = AccountingStore.checkpoint(store, source())
    after
      Store.close(store)
      Store.close(rebuilt)
    end
  end

  @tag :tmp_dir
  test "captured audit-only pages never create measured zero spend", %{tmp_dir: dir} do
    {:ok, store} = Store.open(:memory)

    try do
      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.params["cursor"],
          do: response(conn, "corrupt-audit", 503),
          else: response(conn, "audit-only")
      end)

      assert {:error, %{code: :http_error, http_status: 503}} = GatewayPull.pull(opts(store, dir))
      assert {:ok, [[6]]} = Store.query(store, "SELECT rows FROM ingest_ledger")
      assert :ok = Views.apply(store.conn)
      assert {:ok, []} = Store.query(store, "SELECT * FROM v_gateway_accounting_spend")
      assert {:ok, [[6]]} = Store.query(store, "SELECT count(*) FROM v_gateway_accounting_audits")
    after
      Store.close(store)
    end
  end

  @tag :tmp_dir
  test "malformed audit and mixed schema reject whole HTTP page before publication or acknowledgement",
       %{tmp_dir: dir} do
    {:ok, store} = Store.open(:memory)

    try do
      {:ok, before} = AccountingStore.checkpoint(store, source())

      for {malformed, code} <- [
            {put_in(wire("mixed"), ["rows", Access.at(1), "facts", "outcome"], "secret-token"),
             :invalid_event},
            {put_in(wire("mixed"), ["rows", Access.at(1), "schema_version"], 3),
             :unsupported_version}
          ] do
        Req.Test.stub(GatewayPull, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(malformed))
        end)

        assert {:error, %{code: ^code}} = GatewayPull.pull(opts(store, dir))
        assert {:ok, ^before} = AccountingStore.checkpoint(store, source())
        assert Path.wildcard(Path.join(dir, "*.jsonl")) == []

        for table <-
              ~w(accounting_events accounting_audits accounting_event_ids accounting_states ingest_ledger),
            do: assert({:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM #{table}"))
      end
    after
      Store.close(store)
    end
  end

  @tag :tmp_dir
  test "lost real mixed-page COMMIT acknowledgement reloads durable cursor and refetches", %{
    tmp_dir: dir
  } do
    {:ok, store} = Store.open(:memory)
    {:ok, context} = Agent.start_link(fn -> false end)
    owner = self()

    try do
      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(owner, {:requested_cursor, conn.params["cursor"]})
        if conn.params["cursor"], do: response(conn, "empty"), else: response(conn, "mixed")
      end)

      assert {:ok, %{last_cursor: cursor}} =
               GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.AuditLostAckDB, context}))

      assert_received {:requested_cursor, nil}
      assert_received {:requested_cursor, ^cursor}
      refute_received {:requested_cursor, nil}
      assert {:ok, [[9]]} = Store.query(store, "SELECT count(*) FROM accounting_event_ids")
      assert {:ok, [[3]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
      assert {:ok, [[6]]} = Store.query(store, "SELECT count(*) FROM accounting_audits")
      assert {:ok, [[2]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
    after
      Agent.stop(context)
      Store.close(store)
    end
  end
end

defmodule MimirAnalytics.AccountingAuditsCLITest do
  use ExUnit.Case, async: false
  alias MimirAnalytics.Accounting.{Page, Source}
  alias MimirAnalytics.{AccountingStore, Store}
  alias Mix.Tasks.MimirAnalytics.Ingest

  @tag :tmp_dir
  test "actual gateway CLI retains mixed buffers and rejects an entire malformed audit file", %{
    tmp_dir: dir
  } do
    gateway = Path.join(dir, "gateway")
    File.mkdir_p!(gateway)
    {:ok, source} = Source.new(%{source_id: "test:cli-audit", api_version: 2})
    wire = "test/support/accounting/audits/mixed.json" |> File.read!() |> Jason.decode!()
    {:ok, page} = Page.new(wire, source, nil)
    path = Path.join(gateway, "mixed.jsonl")
    File.write!(path, Page.to_buffer(page))
    db = Path.join(dir, "cli.duckdb")
    argv = ["--db", db, "--gateway", gateway]
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Ingest.run(argv)
      assert_received {:mix_shell, :info, [first]}
      assert first =~ "gateway: 1"
      Ingest.run(argv)
      assert_received {:mix_shell, :info, [second]}
      assert second =~ "gateway: 0"
      refute_received {:mix_shell, :error, _}

      malformed =
        Page.to_buffer(page)
        |> Jason.decode!()
        |> put_in(["rows", Access.at(1), "facts", "outcome"], "bad")
        |> Jason.encode!()

      bad_path = Path.join(gateway, "malformed.jsonl")
      File.write!(bad_path, malformed)
      Ingest.run(argv)
      assert_received {:mix_shell, :error, [message]}
      assert message =~ "malformed.jsonl"
      assert message =~ "invalid_event"
      assert File.read!(path) == Page.to_buffer(page)
      assert File.read!(bad_path) == malformed
      {:ok, store} = Store.open(db)

      try do
        assert {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
        assert {:ok, [[9]]} = Store.query(store, "SELECT rows FROM ingest_ledger")
        assert {:ok, [[9]]} = Store.query(store, "SELECT count(*) FROM accounting_event_ids")
        assert {:ok, [[3]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
        assert {:ok, [[6]]} = Store.query(store, "SELECT count(*) FROM accounting_audits")
        assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(store, source)
      after
        Store.close(store)
      end
    after
      Mix.shell(old_shell)
    end
  end

  @tag :tmp_dir
  test "gateway CLI safely refuses a retained registry conflict", %{tmp_dir: dir} do
    path = Path.join(dir, "conflict.duckdb")
    {:ok, store} = Store.open(path)

    row =
      "test/support/accounting/audits/initial.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("rows")
      |> hd()

    {:ok, source} = Source.new(%{source_id: "test:conflict", api_version: 2})

    {:ok, page} =
      Page.new(
        %{"api_version" => 2, "rows" => [row], "limit" => 500, "next_cursor" => "next"},
        source,
        nil
      )

    {:ok, page} = Page.from_buffer(Page.to_buffer(page), "retained.jsonl")
    assert {:ok, _} = AccountingStore.ingest_page(store, page, :replay)
    assert {:ok, _} = Store.query(store, "UPDATE accounting_event_ids SET kind = 'routing'")
    {:ok, before_receipts} = Store.query(store, "SELECT * FROM ingest_ledger")
    Store.close(store)
    assert_raise Mix.Error, ~r/accounting identity conflict/, fn -> Ingest.run(["--db", path]) end
    {:ok, db} = Duckdbex.open(path)
    {:ok, conn} = Duckdbex.connection(db)

    try do
      retained = %Store{conn: conn}
      assert {:ok, ^before_receipts} = Store.query(retained, "SELECT * FROM ingest_ledger")
      assert {:ok, [[0]]} = Store.query(retained, "SELECT count(*) FROM gateway_checkpoints")
      assert {:ok, [["routing"]]} = Store.query(retained, "SELECT kind FROM accounting_event_ids")
    after
      Duckdbex.release(conn)
      Duckdbex.release(db)
    end
  end
end
