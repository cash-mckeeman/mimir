Code.require_file("test/support/accounting_db_helper.exs")

defmodule MimirAnalytics.AccountingAuditsStoreTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{ExportEvent, Page, Source}
  alias MimirAnalytics.{AccountingStore, Store, Views}

  defp rows,
    do:
      "test/support/accounting/audits/mixed.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("rows")

  defp source(id \\ "test:audit") do
    {:ok, source} = Source.new(%{source_id: id, api_version: 2})
    source
  end

  defp page(rows, next \\ "next", src \\ source()) do
    {:ok, page} =
      Page.new(
        %{"api_version" => 2, "rows" => rows, "limit" => 500, "next_cursor" => next},
        src,
        nil
      )

    {:ok, receipt} = Page.from_buffer(Page.to_buffer(page), "audit.jsonl")
    receipt
  end

  defp count(store, table), do: Store.query(store, "SELECT count(*) FROM #{table}")

  setup do
    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    %{store: store}
  end

  test "mixed and audit-only replays retain exact summary shape and financial seventy", %{
    store: store
  } do
    p = page(rows())

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 3,
                "accounting_audits" => 6,
                "accounting_states" => 1
              }
            }} = AccountingStore.ingest_page(store, p, :replay)

    assert :already_ingested = AccountingStore.ingest_page(store, p, :replay)
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 0,
                "accounting_audits" => 0,
                "accounting_states" => 0
              }
            }} = AccountingStore.ingest_page(store, p, {:advance, cp})

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 0,
                "accounting_audits" => 0,
                "accounting_states" => 0
              }
            }} = AccountingStore.ingest_page(store, page(Enum.reverse(rows())), :replay)

    assert :ok = Views.apply(store.conn)

    assert {:ok, [[70, 0, 0, 0, 0]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars,missing_history_runs,provisional_runs,unreconciled_runs,unknown_price_runs FROM v_gateway_accounting_spend"
             )

    assert {:ok, [[6]]} = count(store, "v_gateway_accounting_audits")
    assert {:ok, [[9]]} = count(store, "accounting_event_ids")

    assert {:ok, [[9], [0]]} =
             Store.query(store, "SELECT rows FROM ingest_ledger ORDER BY rows DESC")

    {:ok, isolated} = Store.open(:memory)

    try do
      audits = Enum.filter(rows(), &(&1["kind"] in ["routing", "lifecycle"]))

      assert {:ok,
              %{
                rows: %{
                  "accounting_events" => 0,
                  "accounting_audits" => 6,
                  "accounting_states" => 0
                }
              }} = AccountingStore.ingest_page(isolated, page(audits), :replay)

      assert :ok = Views.apply(isolated.conn)
      assert {:ok, []} = Store.query(isolated, "SELECT * FROM v_gateway_accounting_spend")
      assert {:ok, [[0]]} = count(isolated, "accounting_states")
    after
      Store.close(isolated)
    end
  end

  test "cross-kind UUID and natural identities conflict both ways without reservations or acknowledgement",
       %{store: store} do
    [financial, route | _] = rows()

    for {winner, loser} <- [{financial, route}, {route, financial}] do
      {:ok, isolated} = Store.open(:memory)

      try do
        assert {:ok, _} = AccountingStore.ingest_page(isolated, page([winner]), :replay)
        {:ok, cp} = AccountingStore.checkpoint(isolated, source())
        loser = Map.put(loser, "event_id", winner["event_id"])

        assert {:error, %{code: :event_conflict}} =
                 AccountingStore.ingest_page(isolated, page([loser]), {:advance, cp})

        assert {:ok, ^cp} = AccountingStore.checkpoint(isolated, source())
        assert {:ok, [[1]]} = count(isolated, "accounting_event_ids")
        assert {:ok, [[1]]} = count(isolated, "ingest_ledger")
      after
        Store.close(isolated)
      end
    end

    assert {:ok, _} = AccountingStore.ingest_page(store, page([route]), :replay)
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    changed = Map.put(route, "event_id", financial["event_id"])

    assert {:error, %{code: :event_conflict}} =
             AccountingStore.ingest_page(store, page([changed]), {:advance, cp})

    assert {:ok, [[1]]} = count(store, "accounting_event_ids")
    assert {:ok, ^cp} = AccountingStore.checkpoint(store, source())
  end

  test "lifecycle natural identity rejects a second UUID for the same submitted run", %{
    store: store
  } do
    lifecycle = Enum.at(rows(), 4)
    assert {:ok, _} = AccountingStore.ingest_page(store, page([lifecycle]), :replay)
    reused = Map.put(lifecycle, "event_id", "00000000-0000-4000-8000-000000000001")

    assert {:error, %{code: :event_conflict}} =
             AccountingStore.ingest_page(store, page([reused]), :replay)

    assert {:ok, [[1]]} = count(store, "accounting_audits")
    assert {:ok, [[1]]} = count(store, "accounting_event_ids")
    assert {:ok, [[1]]} = count(store, "ingest_ledger")
  end

  test "changed audit payload and times conflict while canonical spelling and other sources replay",
       %{store: store} do
    route = Enum.at(rows(), 1)
    assert {:ok, _} = AccountingStore.ingest_page(store, page([route]), :replay)

    for changed <- [
          put_in(route, ["facts", "selected_model"], "different"),
          Map.put(route, "recorded_at", "2026-10-27T00:00:00Z"),
          Map.put(route, "observed_at", "2026-10-27T00:00:00Z")
        ] do
      assert {:error, %{code: :event_conflict}} =
               AccountingStore.ingest_page(store, page([changed]), :replay)
    end

    normalized =
      route
      |> Map.put("event_id", String.upcase(route["event_id"]))
      |> Map.put("observed_at", "2026-10-26T16:12:31.000000+00:00")

    assert :already_ingested = AccountingStore.ingest_page(store, page([normalized]), :replay)

    assert {:ok, _} =
             AccountingStore.ingest_page(
               store,
               page([route], "other", source("other:audit")),
               :replay
             )

    assert {:ok, [[2]]} = count(store, "accounting_event_ids")
    assert {:ok, [[2]]} = count(store, "accounting_audits")
  end

  test "matching registry requires corresponding exact payload row", %{store: store} do
    [financial, route | _] = rows()

    for row <- [financial, route] do
      {:ok, event} = ExportEvent.new(row, source())

      assert {:ok, _} =
               Store.query(store, "INSERT INTO accounting_event_ids VALUES (?, ?, ?, ?)", [
                 event.source_id,
                 event.event_id,
                 row["kind"],
                 ExportEvent.fingerprint(event)
               ])

      assert {:error, %{code: :event_conflict}} =
               AccountingStore.ingest_page(store, page([row]), :replay)
    end

    assert {:ok, [[0]]} = count(store, "ingest_ledger")
    assert {:ok, [[0]]} = count(store, "accounting_events")
    assert {:ok, [[0]]} = count(store, "accounting_audits")
  end

  test "matching registry refuses altered stored payloads without acknowledging new bytes", %{
    store: store
  } do
    [financial, route | _] = rows()

    for {row, table} <- [{financial, "accounting_events"}, {route, "accounting_audits"}] do
      assert {:ok, _} = AccountingStore.ingest_page(store, page([row]), :replay)
      changed = row |> Map.put("request_id", "tampered") |> Jason.encode!()

      assert {:ok, _} =
               Store.query(store, "UPDATE #{table} SET event_json = ? WHERE event_id = ?", [
                 changed,
                 row["event_id"]
               ])

      {:ok, cp} = AccountingStore.checkpoint(store, source())

      assert {:error, %{code: :event_conflict}} =
               AccountingStore.ingest_page(
                 store,
                 page([row], "different-receipt"),
                 {:advance, cp}
               )

      assert {:ok, ^cp} = AccountingStore.checkpoint(store, source())
    end

    assert {:ok, [[2]]} = count(store, "ingest_ledger")
  end

  test "two submitted financial turns sharing session correlation remain separate bookings", %{
    store: store
  } do
    [initial | _] = rows()
    lifecycle = Enum.filter(rows(), &(&1["kind"] == "lifecycle"))
    assert Enum.uniq(Enum.map(lifecycle, & &1["facts"]["session_id"])) == ["sample-session"]

    other =
      Map.merge(initial, %{
        "event_id" => "00000000-0000-4000-8000-000000000001",
        "run_id" => Enum.at(lifecycle, 1)["run_id"]
      })

    assert {:ok,
            %{
              rows: %{
                "accounting_events" => 4,
                "accounting_states" => 2,
                "accounting_audits" => 6
              }
            }} = AccountingStore.ingest_page(store, page(rows() ++ [other]), :replay)

    assert :ok = Views.apply(store.conn)

    assert {:ok, [[170]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars FROM v_gateway_accounting_spend"
             )

    assert {:ok, [[70], [100]]} =
             Store.query(
               store,
               "SELECT booked_total_microdollars FROM accounting_states ORDER BY booked_total_microdollars"
             )
  end

  test "later audit insertion failure rolls registry financial state receipt and checkpoint back",
       %{store: store} do
    [financial, route | _] = rows()
    duplicate = Map.put(route, "event_id", Enum.at(rows(), 2)["event_id"])
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:error, %{code: :event_conflict}} =
             AccountingStore.ingest_page(
               store,
               page([financial, route, duplicate]),
               {:advance, cp}
             )

    for table <-
          ~w(accounting_events accounting_audits accounting_event_ids accounting_states ingest_ledger gateway_checkpoints),
        do: assert({:ok, [[0]]} = count(store, table))
  end

  for contender_mode <- [:replay, :advance] do
    @tag contender_mode: contender_mode
    test "real competing registry writes in replay/#{contender_mode} leave one exact winner", %{
      store: store,
      contender_mode: contender_mode
    } do
      [financial, route | _] = rows()
      route = Map.put(route, "event_id", financial["event_id"])
      {:ok, cp} = AccountingStore.checkpoint(store, source())
      owner = self()

      {:ok, context} =
        Agent.start_link(fn ->
          %{
            leases: 0,
            releases: 0,
            lose_commit_ack: false,
            pause_owner: owner,
            pause_prefixes: ["INSERT INTO accounting_event_ids"]
          }
        end)

      losing = page([route], "losing")
      winning = page([financial], "winning")

      task =
        Task.async(fn ->
          AccountingStore.ingest_page(store, losing, :replay,
            db: {MimirAnalytics.AccountingTestDB, context}
          )
        end)

      assert_receive {:cas_written, worker}, 2_000
      mode = if contender_mode == :advance, do: {:advance, cp}, else: :replay

      assert {:ok, %{rows: %{"accounting_events" => 1, "accounting_states" => 1}}} =
               AccountingStore.ingest_page(store, winning, mode)

      send(worker, :continue_commit)
      assert {:error, %{code: :storage_error}} = Task.await(task)
      assert Agent.get(context, &{&1.leases, &1.releases}) == {1, 1}
      Agent.stop(context)
      {:ok, event} = ExportEvent.new(financial, source())

      assert {:ok, [[id, "initial", fingerprint]]} =
               Store.query(store, "SELECT event_id,kind,fingerprint FROM accounting_event_ids")

      assert id == financial["event_id"]
      assert fingerprint == ExportEvent.fingerprint(event)
      assert {:ok, [[^id]]} = Store.query(store, "SELECT event_id FROM accounting_events")
      assert {:ok, [[0]]} = count(store, "accounting_audits")

      assert {:ok, [[100]]} =
               Store.query(store, "SELECT booked_total_microdollars FROM accounting_states")

      assert {:ok, [[digest, 1]]} = Store.query(store, "SELECT digest,rows FROM ingest_ledger")
      assert digest == winning.digest

      if contender_mode == :advance do
        assert {:ok, %{cursor: "winning", page_digest: ^digest}} =
                 AccountingStore.checkpoint(store, source())
      else
        assert {:ok, ^cp} = AccountingStore.checkpoint(store, source())
      end
    end
  end
end
