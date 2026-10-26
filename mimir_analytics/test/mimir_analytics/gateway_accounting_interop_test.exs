Code.require_file("test/support/accounting_interop_helper.exs")

defmodule MimirAnalytics.GatewayAccountingInteropTest do
  use ExUnit.Case, async: true
  import MimirAnalytics.AccountingInteropHelper

  alias MimirAnalytics.Accounting.{Error, Source}
  alias MimirAnalytics.{AccountingStore, Store, Views}
  alias MimirAnalytics.Ingest.GatewayPull
  alias MimirAnalytics.Mappers.GatewayExport

  setup do
    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    %{store: store}
  end

  defp opts(store, dir) do
    [
      api_version: 2,
      source_id: "test:producer",
      store: store,
      dir: dir,
      base_url: "http://gateway.test",
      token: "synthetic-read-token",
      req_options: [plug: {Req.Test, GatewayPull}]
    ]
  end

  defp checkpoint(store) do
    {:ok, source} = Source.new(%{source_id: "test:producer", api_version: 2})
    AccountingStore.checkpoint(store, source)
  end

  @tag :tmp_dir
  test "captured HTTP pages persist corrected facts and replay reversed repartitions without charging twice",
       %{store: store, tmp_dir: dir} do
    transitions = %{
      nil => "page-1",
      wire("page-1")["next_cursor"] => "page-2",
      wire("page-2")["next_cursor"] => "page-3",
      wire("page-3")["next_cursor"] => "empty-after"
    }

    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      respond(conn, Map.fetch!(transitions, conn.params["cursor"]))
    end)

    assert {:ok, %{files: files, last_cursor: cursor}} = GatewayPull.pull(opts(store, dir))
    assert length(files) == 4
    assert cursor == "eyJ2IjoyLCJzZXF1ZW5jZSI6NjUzfQ"
    assert_main_facts(store)
    assert {:ok, [[4]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
    {:ok, original_checkpoint} = checkpoint(store)
    for file <- files, do: assert(:already_ingested == GatewayExport.ingest(store, file))
    assert {:ok, ^original_checkpoint} = checkpoint(store)

    {:ok, rebuilt} = Store.open(:memory)
    on_exit(fn -> Store.close(rebuilt) end)
    rows = wire("producer")["rows"]
    repartitions = rows |> Enum.reverse() |> Enum.chunk_every(2) |> Enum.with_index()

    for {part, i} <- repartitions do
      file = wrapper(dir, part, "reversed-#{i}")
      assert {:ok, _} = GatewayExport.ingest(rebuilt, file)
      assert :already_ingested = GatewayExport.ingest(rebuilt, file)
    end

    assert_main_facts(rebuilt)
    assert accounting_snapshot(rebuilt) == accounting_snapshot(store)
    assert {:ok, %{cursor: nil}} = checkpoint(rebuilt)
  end

  @tag :tmp_dir
  test "actual provisional corrections and witnessed no-work keep null quotes and distinct measurement facts",
       %{store: store, tmp_dir: dir} do
    # A real producer 503 ends each incremental pull after its committed data page.
    for {name, expected_total, version} <- [
          {"producer_provisional_initial", 100, 1},
          {"producer_corrections", 70, 3},
          {"producer_no_work", 70, 3}
        ] do
      {:ok, before} = checkpoint(store)

      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.params["cursor"] == before.cursor,
          do: respond(conn, name),
          else: respond(conn, "error503-json-array", 503)
      end)

      assert {:error, %Error{code: :http_error, http_status: 503}} =
               GatewayPull.pull(opts(store, dir))

      assert {:ok,
              %{booked_total_microdollars: ^expected_total, latest: %{booking_version: ^version}}} =
               AccountingStore.get_state(
                 store,
                 "test:producer",
                 "c0059c67-4149-49b9-9e18-c1668bc71a41",
                 "6f2d5402-bfd8-48ad-9ba5-80aeaadf82ba"
               )
    end

    assert {:ok, [[false, nil, nil, nil, "provisional", "incomplete"]]} =
             Store.query(store, """
             SELECT CAST(event_json->>'complete' AS BOOLEAN), CAST(event_json->>'input_tokens' AS BIGINT),
                    event_json->>'model', CAST(event_json->>'quoted_cost_microdollars' AS BIGINT),
                    event_json->>'charge_state', event_json->>'priceability'
             FROM accounting_events WHERE booking_version = 1 AND run_id = '6f2d5402-bfd8-48ad-9ba5-80aeaadf82ba'
             """)

    assert {:ok,
            [
              [
                true,
                nil,
                nil,
                "no_provider_work",
                "not_applicable",
                "settled",
                "error",
                "validation_error",
                0
              ]
            ]} =
             Store.query(store, """
             SELECT CAST(event_json->>'complete' AS BOOLEAN), event_json->>'model',
                    CAST(event_json->>'quoted_cost_microdollars' AS BIGINT), event_json->>'authority',
                    event_json->>'priceability', event_json->>'charge_state',
                    event_json->>'execution_outcome', event_json->>'error_class',
                    CAST(event_json->>'delta_microdollars' AS BIGINT)
             FROM accounting_events WHERE run_id = '0f51460b-385f-455f-8153-8119d0dd90ba'
             """)

    :ok = Views.apply(store.conn)
    assert {:ok, [[70, 0, 0, 0, 0]]} = spend(store, "c0059c67-4149-49b9-9e18-c1668bc71a41")
    assert {:ok, [[0, 0, 0, 0, 0]]} = spend(store, "8554f0c2-2823-4664-8167-eb5cc7ea071d")
    assert {:ok, [[4]]} = Store.query(store, "SELECT count(*) FROM accounting_events")

    Req.Test.stub(GatewayPull, &respond(&1, "producer_empty_final"))
    assert {:ok, %{files: [_]}} = GatewayPull.pull(opts(store, dir))
    assert {:ok, [[4]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")

    for file <- Path.wildcard(Path.join(dir, "*.jsonl")),
        do: assert(:already_ingested == GatewayExport.ingest(store, file))
  end

  @tag :tmp_dir
  test "captured omitted and resumed empty positions retain zero-event provenance", %{
    store: store,
    tmp_dir: dir
  } do
    Req.Test.stub(GatewayPull, &respond(&1, "producer_empty_omitted"))
    assert {:ok, %{files: [first], last_cursor: token}} = GatewayPull.pull(opts(store, dir))
    assert token == "eyJ2IjoyLCJzZXF1ZW5jZSI6MH0"
    Req.Test.stub(GatewayPull, &respond(&1, "producer_empty_zero"))
    assert {:ok, %{files: [resumed], last_cursor: ^token}} = GatewayPull.pull(opts(store, dir))
    refute first == resumed
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_states")

    assert {:ok, [[2, 0]]} =
             Store.query(store, "SELECT count(*), CAST(sum(rows) AS BIGINT) FROM ingest_ledger")

    {:ok, expected} = checkpoint(store)

    for file <- [first, resumed],
        do: assert(:already_ingested == GatewayExport.ingest(store, file))

    assert {:ok, ^expected} = checkpoint(store)
  end
end
