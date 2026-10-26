defmodule MimirAnalytics.AccountingStoreTest do
  use ExUnit.Case, async: true
  Code.require_file("test/support/accounting_db_helper.exs")
  alias MimirAnalytics.Accounting.{Page, Source}
  alias MimirAnalytics.{AccountingStore, Store, Views}

  defp source do
    {:ok, source} = Source.new(%{source_id: "test:gateway", api_version: 2})
    source
  end

  defp wire, do: "test/support/accounting/producer.json" |> File.read!() |> Jason.decode!()

  defp page(rows, from \\ nil, next \\ "next") do
    {:ok, page} =
      Page.new(Map.merge(wire(), %{"rows" => rows, "next_cursor" => next}), source(), from)

    {:ok, receipt} = Page.from_buffer(Page.to_buffer(page), "page.jsonl")
    receipt
  end

  defp raw_page(rows) do
    json =
      page(rows)
      |> Page.to_buffer()
      |> Jason.decode!()
      |> Map.put("rows", rows)
      |> Jason.encode!()

    {:ok, receipt} = Page.from_buffer(json, "raw.jsonl")
    receipt
  end

  setup do
    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    %{store: store}
  end

  test "repartitioned immutable events deduplicate and exact replay preserves status", %{
    store: store
  } do
    [a, b, c, z, u] = wire()["rows"]

    assert {:ok, %{rows: %{"accounting_events" => 1, "accounting_states" => 1}}} =
             AccountingStore.ingest_page(store, page([c]), :replay)

    assert {:ok, state} =
             AccountingStore.get_state(
               store,
               source().source_id,
               a["virtual_key_id"],
               a["run_id"]
             )

    assert state.booked_total_microdollars == nil

    assert {:ok, %{rows: %{"accounting_events" => 4, "accounting_states" => 3}}} =
             AccountingStore.ingest_page(store, page([a, b, c, z, u]), :replay)

    assert :already_ingested = AccountingStore.ingest_page(store, page([a, b, c, z, u]), :replay)

    assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
             AccountingStore.ingest_page(store, page([c, b, a, u, z]), :replay)

    assert {:ok, %{booked_total_microdollars: 70, latest: %{booking_version: 3}}} =
             AccountingStore.get_state(
               store,
               source().source_id,
               a["virtual_key_id"],
               a["run_id"]
             )

    assert :miss = AccountingStore.get_state(store, "absent", a["virtual_key_id"], a["run_id"])
    assert :ok = Views.apply(store.conn)

    assert {:ok, [[0, 0, 0, 1, 1]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars,missing_history_runs,provisional_runs,unreconciled_runs,unknown_price_runs FROM v_gateway_accounting_spend WHERE virtual_key_id = ?",
               [u["virtual_key_id"]]
             )
  end

  test "conflicts roll back whole pages including checkpoint", %{store: store} do
    [a, b | _] = wire()["rows"]
    assert {:ok, _} = AccountingStore.ingest_page(store, page([a]), :replay)
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    changed = Map.put(a, "observed_at", "2026-09-29T11:00:00Z")

    assert {:error, %{code: :event_conflict}} =
             AccountingStore.ingest_page(store, page([b, changed]), {:advance, cp})

    assert {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, ^cp} = AccountingStore.checkpoint(store, source())
  end

  test "checked CAS cannot be bypassed by ledgered bytes", %{store: store} do
    p = page(wire()["rows"])
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    assert {:ok, _} = AccountingStore.ingest_page(store, p, :replay)

    assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
             AccountingStore.ingest_page(store, p, {:advance, cp})

    assert {:error, %{code: :checkpoint_conflict}} =
             AccountingStore.ingest_page(store, p, {:advance, cp})

    assert {:ok, %{cursor: "next", page_digest: digest}} =
             AccountingStore.checkpoint(store, source())

    assert digest == p.digest
  end

  test "uncertain commit releases its lease and fresh checkpoint observes durable progress", %{
    store: store
  } do
    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: true, pause_owner: nil}
      end)

    on_exit(fn -> if Process.alive?(context), do: Agent.stop(context) end)
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    p = page(wire()["rows"])

    assert {:error, %{code: :commit_uncertain}} =
             AccountingStore.ingest_page(store, p, {:advance, cp},
               db: {MimirAnalytics.AccountingTestDB, context}
             )

    assert Agent.get(context, &{&1.leases, &1.releases}) == {1, 1}

    assert {:ok, %{cursor: "next"}} =
             AccountingStore.checkpoint(store, source(),
               db: {MimirAnalytics.AccountingTestDB, context}
             )

    assert Agent.get(context, &{&1.leases, &1.releases}) == {2, 2}
    assert {:ok, [[5]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end

  test "uncommitted competing CAS fails safely and leaves one winner", %{store: store} do
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    assert {:ok, _} = AccountingStore.ingest_page(store, page([], nil, "start"), {:advance, cp})
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: owner}
      end)

    p = page(wire()["rows"], "start", "next")

    task =
      Task.async(fn ->
        AccountingStore.ingest_page(store, p, {:advance, cp},
          db: {MimirAnalytics.AccountingTestDB, context}
        )
      end)

    assert_receive {:cas_written, worker}, 2_000

    assert {:error, %{code: :storage_error}} =
             AccountingStore.ingest_page(store, p, {:advance, cp})

    send(worker, :continue_commit)
    assert {:ok, _} = Task.await(task)
    assert Agent.get(context, &{&1.leases, &1.releases}) == {1, 1}
    Agent.stop(context)
    assert {:ok, [[5]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end

  test "native file reopen retains canonical fingerprints and whole-page conflict rollback" do
    directory =
      "/private/tmp/analytics-accounting-#{System.pid()}-#{System.unique_integer([:positive])}"

    File.mkdir!(directory)
    path = Path.join(directory, "history.duckdb")
    [a, b | _] = wire()["rows"]
    {:ok, first} = Store.open(path)

    try do
      assert {:ok, _} = AccountingStore.ingest_page(first, page([a]), :replay)
    after
      Store.close(first)
    end

    {:ok, reopened} = Store.open(path)

    try do
      normalized =
        Map.merge(a, %{
          "event_id" => String.upcase(a["event_id"]),
          "observed_at" => "2026-09-29T10:00:00.000000+00:00",
          "recorded_at" => String.replace(a["recorded_at"], "Z", "+00:00")
        })

      assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
               AccountingStore.ingest_page(reopened, raw_page([normalized]), :replay)

      assert {:error, %{code: :event_conflict}} =
               AccountingStore.ingest_page(
                 reopened,
                 page([b, Map.put(a, "recorded_at", "2026-10-26T05:00:00Z")]),
                 :replay
               )

      assert {:ok, [[1]]} = Store.query(reopened, "SELECT count(*) FROM accounting_events")
    after
      Store.close(reopened)
      File.rm!(path)
      File.rmdir!(directory)
    end
  end

  test "booking conflicts and inconsistent deltas roll back all inserted rows", %{store: store} do
    [a, b | _] = wire()["rows"]

    assert {:error, %{code: :booking_conflict}} =
             AccountingStore.ingest_page(
               store,
               page([a, Map.put(a, "event_id", b["event_id"])]),
               :replay
             )

    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")

    assert {:error, %{code: :inconsistent_history}} =
             AccountingStore.ingest_page(
               store,
               page([a, Map.put(b, "delta_microdollars", -19)]),
               :replay
             )

    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
  end

  test "buffer validation rejects malformed mixed and nonadvancing pages" do
    assert {:error, _} = Page.from_buffer("{}\n{}\n", "page.jsonl")
    assert {:error, _} = Page.new(Map.put(wire(), "next_cursor", "same"), source(), "same")

    assert {:error, _} =
             Page.new(
               Map.put(wire(), "rows", [Map.put(hd(wire()["rows"]), "kind", "routing")]),
               source(),
               nil
             )
  end

  test "API versions reject numeric coercion" do
    for version <- [2.0, nil, "2", 3] do
      assert {:error, %{code: :unsupported_version}} =
               Page.new(Map.put(wire(), "api_version", version), source(), nil)
    end
  end

  test "all ingestion permutations reconstruct one total across separate page digests" do
    [a, b, c | _] = wire()["rows"]

    for order <- [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] do
      {:ok, isolated} = Store.open(:memory)

      try do
        for row <- order,
            do: assert({:ok, _} = AccountingStore.ingest_page(isolated, page([row]), :replay))

        assert {:ok,
                %{
                  history: :complete,
                  booked_total_microdollars: 70,
                  latest: %{booking_version: 3, measurement_version: 13}
                }} =
                 AccountingStore.get_state(
                   isolated,
                   source().source_id,
                   a["virtual_key_id"],
                   a["run_id"]
                 )

        assert {:ok, [[3]]} = Store.query(isolated, "SELECT count(*) FROM accounting_events")
      after
        Store.close(isolated)
      end
    end
  end

  test "failed begin never rolls back another transaction and always releases lease", %{
    store: store
  } do
    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: nil, prebegin: true}
      end)

    assert {:error, %{code: :storage_error}} =
             AccountingStore.ingest_page(store, page(wire()["rows"]), :replay,
               db: {MimirAnalytics.AccountingTestDB, context}
             )

    assert Agent.get(context, &{&1.leases, &1.releases, &1.commands}) == {1, 1, [:begin]}
    Agent.stop(context)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end

  test "database query failure rolls back owned work and leaves caller connection usable", %{
    store: store
  } do
    assert {:ok, _} = Store.query(store, "DROP TABLE accounting_states")

    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: nil}
      end)

    assert {:error, %{code: :storage_error}} =
             AccountingStore.ingest_page(store, page(wire()["rows"]), :replay,
               db: {MimirAnalytics.AccountingTestDB, context}
             )

    assert Agent.get(context, &{&1.leases, &1.releases}) == {1, 1}
    assert :rollback in Agent.get(context, & &1.commands)
    Agent.stop(context)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
  end

  test "unexpected pure mapping exceptions roll back and re-raise", %{store: store} do
    p = page(wire()["rows"])
    p = %{p | events: [hd(p.events), :invalid_internal_event]}

    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: nil}
      end)

    assert_raise FunctionClauseError, fn ->
      AccountingStore.ingest_page(store, p, :replay,
        db: {MimirAnalytics.AccountingTestDB, context}
      )
    end

    assert Agent.get(context, &{&1.leases, &1.releases}) == {1, 1}
    assert :rollback in Agent.get(context, & &1.commands)
    Agent.stop(context)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end

  test "accounting leases never commit or close the caller connection", %{store: store} do
    assert {:ok, _} = Store.query(store, "BEGIN")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, _} = AccountingStore.ingest_page(store, page(wire()["rows"]), :replay)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, _} = Store.query(store, "ROLLBACK")
    assert {:ok, [[5]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
  end

  test "concurrent absent checkpoint CAS commits one complete page and classifies deferred uniqueness",
       %{store: store} do
    [a, b, c | _] = wire()["rows"]
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: owner}
      end)

    p = page([a, b], nil, "first")
    winner = page([b, c], nil, "second")

    task =
      Task.async(fn ->
        AccountingStore.ingest_page(store, p, {:advance, cp},
          db: {MimirAnalytics.AccountingTestDB, context}
        )
      end)

    assert_receive {:cas_written, worker}, 2_000

    assert {:ok, %{rows: %{"accounting_events" => 2, "accounting_states" => 1}}} =
             AccountingStore.ingest_page(store, winner, {:advance, cp})

    send(worker, :continue_commit)
    assert {:error, %{code: :checkpoint_conflict}} = Task.await(task)
    assert Agent.get(context, &{&1.leases, &1.releases}) == {2, 2}
    Agent.stop(context)

    assert {:ok, [[id_b], [id_c]]} =
             Store.query(store, "SELECT event_id FROM accounting_events ORDER BY booking_version")

    assert [id_b, id_c] == [b["event_id"], c["event_id"]]

    assert {:ok,
            %{
              history: {:missing_versions, [1..1]},
              booked_total_microdollars: nil,
              latest: %{booking_version: 3}
            }} =
             AccountingStore.get_state(
               store,
               source().source_id,
               a["virtual_key_id"],
               a["run_id"]
             )

    assert {:ok, [[digest, 2]]} = Store.query(store, "SELECT digest,rows FROM ingest_ledger")
    assert digest == winner.digest

    assert {:ok, %{cursor: "second", page_digest: ^digest}} =
             AccountingStore.checkpoint(store, source())
  end

  test "producer provisional and correction pages retain uncertainty then reconstruct seventy", %{
    store: store
  } do
    [initial, b, c, no_work] =
      "test/support/accounting/producer_invariants.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("rows")

    assert {:ok, _} = AccountingStore.ingest_page(store, page([initial, no_work]), :replay)
    assert :ok = Views.apply(store.conn)

    assert {:ok, [[100, 1, 1]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars,provisional_runs,unknown_price_runs FROM v_gateway_accounting_spend WHERE virtual_key_id = ?",
               [initial["virtual_key_id"]]
             )

    assert {:ok, [[0, 0, 0]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars,provisional_runs,unknown_price_runs FROM v_gateway_accounting_spend WHERE virtual_key_id = ?",
               [no_work["virtual_key_id"]]
             )

    assert {:ok, %{rows: %{"accounting_events" => 2, "accounting_states" => 1}}} =
             AccountingStore.ingest_page(store, page([c, b]), :replay)

    assert {:ok,
            %{
              history: :complete,
              booked_total_microdollars: 70,
              latest: %{measurement_version: 13, booking_version: 3}
            }} =
             AccountingStore.get_state(
               store,
               source().source_id,
               initial["virtual_key_id"],
               initial["run_id"]
             )

    assert {:ok, [[70, 0, 0]]} =
             Store.query(
               store,
               "SELECT booked_applied_total_microdollars,provisional_runs,unknown_price_runs FROM v_gateway_accounting_spend WHERE virtual_key_id = ?",
               [initial["virtual_key_id"]]
             )
  end

  test "producer empty pages permit only initial position or retained resumed cursor", %{
    store: store
  } do
    for name <- [
          "producer_empty_omitted.json",
          "producer_empty_zero.json",
          "producer_empty_final.json"
        ] do
      body = Path.join("test/support/accounting", name) |> File.read!() |> Jason.decode!()
      from = if name == "producer_empty_omitted.json", do: nil, else: body["next_cursor"]
      assert {:ok, page} = Page.new(body, source(), from)
      assert page.events == []
      assert page.next_cursor == body["next_cursor"]
      assert {:ok, receipt} = Page.from_buffer(Page.to_buffer(page), name)

      assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
               AccountingStore.ingest_page(store, receipt, :replay)

      assert :already_ingested = AccountingStore.ingest_page(store, receipt, :replay)
    end

    assert {:ok, %{cursor: nil, page_digest: nil}} = AccountingStore.checkpoint(store, source())
  end

  test "known commit constraint without changed checkpoint stays storage error", %{store: store} do
    [a, b | _] = wire()["rows"]
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{
          leases: 0,
          releases: 0,
          lose_commit_ack: false,
          pause_owner: owner,
          pause_prefixes: ["INSERT INTO ingest_ledger"]
        }
      end)

    p = page([a, b])

    task =
      Task.async(fn ->
        AccountingStore.ingest_page(store, p, {:advance, cp},
          db: {MimirAnalytics.AccountingTestDB, context}
        )
      end)

    assert_receive {:cas_written, worker}, 2_000

    assert {:ok, %{rows: %{"accounting_events" => 2, "accounting_states" => 1}}} =
             AccountingStore.ingest_page(store, p, :replay)

    send(worker, :continue_commit)
    assert {:error, %{code: :storage_error}} = Task.await(task)
    assert Agent.get(context, &{&1.leases, &1.releases}) == {2, 2}
    Agent.stop(context)
    assert {:ok, ^cp} = AccountingStore.checkpoint(store, source())
    assert {:ok, [[2]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[1]]} = Store.query(store, "SELECT count(*) FROM ingest_ledger")
  end

  test "source identity isolates immutable IDs and checkpoints", %{store: store} do
    body = wire()
    {:ok, first_cp} = AccountingStore.checkpoint(store, source())
    assert {:ok, _} = AccountingStore.ingest_page(store, page(body["rows"]), {:advance, first_cp})
    {:ok, other} = Source.new(%{source_id: "other:gateway", api_version: 2})
    {:ok, p} = Page.new(body, other, nil)
    {:ok, receipt} = Page.from_buffer(Page.to_buffer(p), "other.jsonl")
    {:ok, other_cp} = AccountingStore.checkpoint(store, other)
    assert other_cp.cursor == nil

    assert {:ok, %{rows: %{"accounting_events" => 5, "accounting_states" => 3}}} =
             AccountingStore.ingest_page(store, receipt, {:advance, other_cp})

    assert {:ok, [[10]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[2]]} = Store.query(store, "SELECT count(*) FROM gateway_checkpoints")
  end

  test "retained empty cursor still compares checkpoint digest on ledgered advancement", %{
    store: store
  } do
    {:ok, absent} = AccountingStore.checkpoint(store, source())

    assert {:ok, _} =
             AccountingStore.ingest_page(store, page([], nil, "retained"), {:advance, absent})

    {:ok, prior} = AccountingStore.checkpoint(store, source())
    resumed = page([], "retained", "retained")

    assert {:ok, %{rows: %{"accounting_events" => 0, "accounting_states" => 0}}} =
             AccountingStore.ingest_page(store, resumed, {:advance, prior})

    {:ok, current} = AccountingStore.checkpoint(store, source())
    assert current.cursor == prior.cursor
    refute current.page_digest == prior.page_digest

    assert {:error, %{code: :checkpoint_conflict}} =
             AccountingStore.ingest_page(store, resumed, {:advance, prior})

    assert {:ok, ^current} = AccountingStore.checkpoint(store, source())
  end

  test "deferred first-checkpoint commit conflict reloads winner after releasing old lease", %{
    store: store
  } do
    {:ok, absent} = AccountingStore.checkpoint(store, source())
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{leases: 0, releases: 0, lose_commit_ack: false, pause_owner: owner}
      end)

    losing = page([], nil, "first")
    winner = page([], nil, "second")

    task =
      Task.async(fn ->
        AccountingStore.ingest_page(store, losing, {:advance, absent},
          db: {MimirAnalytics.AccountingTestDB, context}
        )
      end)

    assert_receive {:cas_written, worker}, 2_000
    assert {:ok, _} = AccountingStore.ingest_page(store, winner, {:advance, absent})
    send(worker, :continue_commit)
    assert {:error, %{code: :checkpoint_conflict}} = Task.await(task)
    assert Agent.get(context, &{&1.leases, &1.releases}) == {2, 2}
    Agent.stop(context)
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM accounting_states")
    assert {:ok, [[digest, 0]]} = Store.query(store, "SELECT digest,rows FROM ingest_ledger")
    assert digest == winner.digest

    assert {:ok, %{cursor: "second", page_digest: ^digest}} =
             AccountingStore.checkpoint(store, source())
  end
end
