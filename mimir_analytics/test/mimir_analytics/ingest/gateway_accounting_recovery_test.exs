defmodule MimirAnalytics.AccountingPublicationTestFS do
  @moduledoc false
  @behaviour MimirAnalytics.Ingest.GatewayAccountingBuffer.FileSystem
  alias MimirAnalytics.Ingest.GatewayAccountingBuffer.FileSystem

  @impl true
  @spec read(Path.t(), pid()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path, context) do
    result = File.read(path)

    if result == {:error, :enoent} do
      {owner, pause?} =
        Agent.get_and_update(context, fn state ->
          {{state.owner, not state.paused? and Map.get(state, :pause_read?, true)},
           %{state | paused?: true}}
        end)

      if pause? do
        send(owner, {:destination_absent, self(), path})

        receive do
          :publish -> :ok
        after
          5_000 -> raise "publication barrier timed out"
        end
      end
    end

    result
  end

  @impl true
  @spec write(Path.t(), binary(), [:binary | :exclusive | :sync], pid()) :: FileSystem.result()
  def write(path, bytes, modes, context) do
    config = Agent.get(context, & &1)

    if Map.get(config, :pause_write?, false) do
      send(config.owner, {:before_exclusive_write, self(), path})

      receive do
        :write -> :ok
      after
        5_000 -> raise "temporary ownership barrier timed out"
      end
    end

    result = File.write(path, bytes, modes)
    if Map.get(config, :pause_write?, false), do: send(config.owner, {:exclusive_write, result})
    result
  end

  @impl true
  @spec mkdir_p(Path.t(), pid()) :: FileSystem.result()
  def mkdir_p(path, _context), do: File.mkdir_p(path)
  @impl true
  @spec ln(Path.t(), Path.t(), pid()) :: FileSystem.result()
  def ln(from, to, _context), do: File.ln(from, to)
  @impl true
  @spec rm(Path.t(), pid()) :: FileSystem.result()
  def rm(path, _context), do: File.rm(path)
end

defmodule MimirAnalytics.GatewayRecoveryDB do
  @moduledoc false
  @behaviour MimirAnalytics.Store.DB
  alias MimirAnalytics.Store
  alias MimirAnalytics.Store.{DB, DuckDB}

  @impl true
  @spec lease(Store.t(), pid()) :: {:ok, Store.t()} | {:error, :unavailable}
  def lease(store, context) do
    {:ok, lease} = DuckDB.lease(store, nil)
    n = Agent.get_and_update(context, fn c -> {c.leases + 1, %{c | leases: c.leases + 1}} end)

    if Agent.get(context, &Map.get(&1, :prebegin, false)) and n == 2 do
      {:ok, _} = DuckDB.command(lease, :begin, nil)
      {:ok, _} = Store.query(lease, "INSERT INTO sentinel VALUES (71)")

      send(
        Agent.get(context, & &1.owner),
        {:before_nested, Store.query(lease, "SELECT * FROM sentinel")}
      )
    end

    {:ok, lease}
  end

  @impl true
  @spec release(Store.t(), pid()) :: :ok
  def release(lease, context) do
    config = Agent.get(context, & &1)

    if Map.get(config, :prebegin, false) and config.leases == 2 do
      send(config.owner, {:sentinel, Store.query(lease, "SELECT * FROM sentinel")})
      {:ok, _} = DuckDB.command(lease, :rollback, nil)
    end

    :ok = DuckDB.release(lease, nil)
    Agent.update(context, &%{&1 | releases: &1.releases + 1})
  end

  @impl true
  @spec command(Store.t(), DB.command(), pid()) :: {:ok, [[term()]]} | {:error, DB.failure()}
  def command(lease, cmd, context) do
    config = Agent.get(context, & &1)

    if cmd == :commit and Map.get(config, :abort_commit, false) do
      {:error, _} = Store.query(lease, "INSERT INTO sentinel VALUES (1), (1)")
    end

    result = DuckDB.command(lease, cmd, nil)
    Agent.update(context, &%{&1 | commands: [cmd | &1.commands]})
    maybe_pause(cmd, result, config)

    if cmd == :commit and config.lose_ack do
      Agent.update(context, &Map.put(&1, :lose_ack, Map.get(config, :always_lose_ack, false)))
      send(config.owner, {:lost_ack, result, config.leases, config.releases})
      {:error, :unavailable}
    else
      result
    end
  end

  defp maybe_pause({:query, sql, _}, {:ok, _}, %{pause: prefix, owner: owner}) do
    if String.starts_with?(sql, prefix) do
      send(owner, {:paused, self()})

      receive do
        :resume -> :ok
        :interrupt -> exit(:interrupted)
      after
        5_000 -> raise "recovery barrier timed out"
      end
    end
  end

  defp maybe_pause(_, _, _), do: :ok
end

defmodule MimirAnalytics.Ingest.GatewayAccountingRecoveryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias MimirAnalytics.Accounting.{Page, Source}
  alias MimirAnalytics.AccountingPublicationTestFS
  alias MimirAnalytics.{AccountingStore, Store}
  alias MimirAnalytics.Ingest.{GatewayAccountingBuffer, GatewayPull}
  alias MimirAnalytics.Mappers.GatewayExport
  alias Mix.Tasks.MimirAnalytics.Ingest

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "accounting-recovery-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    {:ok, store} = Store.open(Path.join(dir, "owned.duckdb"))

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  defp source(id \\ "test:recovery") do
    {:ok, source} = Source.new(%{source_id: id, api_version: 2})
    source
  end

  defp rows,
    do:
      "test/support/accounting/producer.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("rows")

  defp body(rows, cursor),
    do: %{"api_version" => 2, "limit" => 500, "rows" => rows, "next_cursor" => cursor}

  defp page(rows, from, next, id \\ "test:recovery") do
    {:ok, page} = Page.new(body(rows, next), source(id), from)
    page
  end

  defp receipt(rows, from, next) do
    {:ok, receipt} = Page.from_buffer(Page.to_buffer(page(rows, from, next)), "test.jsonl")
    receipt
  end

  defp opts(store, dir, extra \\ []),
    do:
      Keyword.merge(
        [
          api_version: 2,
          source_id: "test:recovery",
          store: store,
          dir: Path.join(dir, "buffers"),
          base_url: "http://gateway.test",
          token: "secret",
          req_options: [plug: {Req.Test, GatewayPull}]
        ],
        extra
      )

  defp context(extra) do
    {:ok, context} =
      Agent.start_link(fn ->
        Map.merge(%{owner: self(), leases: 0, releases: 0, commands: [], lose_ack: false}, extra)
      end)

    context
  end

  defp count(store, table), do: Store.query(store, "SELECT count(*) FROM #{table}")

  defp assert_empty(store) do
    for table <- [
          "accounting_events",
          "accounting_states",
          "ingest_ledger",
          "gateway_checkpoints"
        ],
        do: assert(count(store, table) == {:ok, [[0]]})
  end

  defp default_http do
    data = rows()

    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      Req.Test.json(conn, body(if(conn.params["cursor"], do: [], else: data), "next"))
    end)
  end

  test "publication is unacknowledged, repeatable, collision-checked and mapper replay never advances",
       %{store: store, dir: dir} do
    p = page(rows(), nil, "next")
    assert {:ok, receipt, path} = GatewayAccountingBuffer.publish(p, dir)
    assert Path.basename(path) == "gateway_accounting-#{receipt.digest}.jsonl"
    assert {:ok, ^receipt, ^path} = GatewayAccountingBuffer.publish(p, dir)
    assert_empty(store)
    assert {:ok, %{rows: %{"accounting_events" => 5}}} = GatewayExport.ingest(store, path)
    assert :already_ingested = GatewayExport.ingest(store, path)
    assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(store, source())
    {:ok, cp} = AccountingStore.checkpoint(store, source())
    assert {:ok, _} = AccountingStore.ingest_page(store, receipt, {:advance, cp})

    assert {:error, %{code: :checkpoint_conflict}} =
             AccountingStore.ingest_page(store, receipt, {:advance, cp})

    assert count(store, "accounting_events") == {:ok, [[5]]}
    File.write!(path, "collision-secret")
    assert {:error, %{code: :buffer_error}} = GatewayAccountingBuffer.publish(p, dir)
    assert File.read!(path) == "collision-secret"
    assert Path.wildcard(Path.join(dir, ".*.tmp"), match_dot: true) == []
  end

  test "a mismatched destination created after absence is never replaced", %{
    store: store,
    dir: dir
  } do
    owner = self()
    {:ok, context} = Agent.start_link(fn -> %{owner: owner, paused?: false} end)
    p = page(rows(), nil, "next")

    task =
      Task.async(fn ->
        GatewayAccountingBuffer.publish(p, dir,
          file_system: {AccountingPublicationTestFS, context}
        )
      end)

    assert_receive {:destination_absent, worker, destination}, 2_000
    refute File.exists?(destination)
    File.write!(destination, "concurrent-owner-bytes")
    send(worker, :publish)
    assert {:error, %{code: :buffer_error}} = Task.await(task)
    assert File.read!(destination) == "concurrent-owner-bytes"
    assert_empty(store)
    assert Path.wildcard(Path.join(dir, ".*.tmp"), match_dot: true) == []
    Agent.stop(context)
  end

  test "matching concurrent publication after absence reuses the complete destination", %{
    store: store,
    dir: dir
  } do
    owner = self()
    {:ok, context} = Agent.start_link(fn -> %{owner: owner, paused?: false} end)
    p = page(rows(), nil, "next")

    task =
      Task.async(fn ->
        GatewayAccountingBuffer.publish(p, dir,
          file_system: {AccountingPublicationTestFS, context}
        )
      end)

    assert_receive {:destination_absent, worker, destination}, 2_000
    assert {:ok, receipt, ^destination} = GatewayAccountingBuffer.publish(p, dir)
    committed_bytes = File.read!(destination)
    send(worker, :publish)
    assert {:ok, ^receipt, ^destination} = Task.await(task)
    assert File.read!(destination) == committed_bytes
    assert Path.wildcard(Path.join(dir, "*.jsonl")) == [destination]
    assert Path.wildcard(Path.join(dir, ".*.tmp"), match_dot: true) == []
    assert_empty(store)
    Agent.stop(context)
  end

  test "failed exclusive create preserves a preoccupied candidate temporary", %{
    store: store,
    dir: dir
  } do
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{owner: owner, paused?: false, pause_read?: false, pause_write?: true}
      end)

    task =
      Task.async(fn ->
        GatewayAccountingBuffer.publish(page(rows(), nil, "next"), dir,
          file_system: {AccountingPublicationTestFS, context}
        )
      end)

    assert_receive {:before_exclusive_write, worker, candidate}, 2_000
    File.write!(candidate, "preexisting-owner-bytes")
    send(worker, :write)
    assert {:error, %{code: :buffer_error}} = Task.await(task)
    assert_receive {:exclusive_write, {:error, :eexist}}
    assert File.read(candidate) == {:ok, "preexisting-owner-bytes"}
    assert Path.wildcard(Path.join(dir, "*.jsonl")) == []
    assert_empty(store)
    Agent.stop(context)
  end

  test "failed publisher leaves an active temporary owner able to finish publication", %{
    store: store,
    dir: dir
  } do
    owner = self()

    {:ok, context} =
      Agent.start_link(fn ->
        %{owner: owner, paused?: false, pause_read?: false, pause_write?: true}
      end)

    p = page(rows(), nil, "next")

    task =
      Task.async(fn ->
        GatewayAccountingBuffer.publish(p, dir,
          file_system: {AccountingPublicationTestFS, context}
        )
      end)

    assert_receive {:before_exclusive_write, worker, candidate}, 2_000
    bytes = Page.to_buffer(p)
    {first, rest} = :erlang.split_binary(bytes, div(byte_size(bytes), 2))
    {:ok, device} = File.open(candidate, [:write, :exclusive, :binary])

    try do
      :ok = IO.binwrite(device, first)
      send(worker, :write)
      assert {:error, %{code: :buffer_error}} = Task.await(task)
      assert_receive {:exclusive_write, {:error, :eexist}}
      assert File.read(candidate) == {:ok, first}
      :ok = IO.binwrite(device, rest)
    after
      File.close(device)
    end

    final = Path.join(dir, "owner_page.jsonl")
    assert :ok = File.ln(candidate, final)
    assert File.read!(final) == bytes
    assert {:ok, %{rows: %{"accounting_events" => 5}}} = GatewayExport.ingest(store, final)
    assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(store, source())
    Agent.stop(context)
  end

  test "unwritable directory rejects publication before acknowledgement", %{
    store: store,
    dir: dir
  } do
    path = Path.join(dir, "readonly")
    File.mkdir!(path)
    File.chmod!(path, 0o500)
    default_http()

    try do
      assert {:error, %{code: :buffer_error}} = GatewayPull.pull(opts(store, dir, dir: path))
      assert_empty(store)
    after
      File.chmod!(path, 0o700)
    end
  end

  test "interruption after publication and file loss before commit refetches old checkpoint", %{
    store: store,
    dir: dir
  } do
    owner = self()
    config = context(%{owner: owner, pause: "INSERT INTO gateway_checkpoints"})
    default_http()

    task =
      Task.async(fn ->
        try do
          GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))
        catch
          :exit, :interrupted -> :interrupted
        end
      end)

    assert_receive {:paused, worker}, 2_000
    [orphan] = Path.wildcard(Path.join([dir, "buffers", "*.jsonl"]))
    File.rm!(orphan)
    assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(store, source())
    send(worker, :interrupt)
    assert :interrupted = Task.await(task)
    assert_empty(store)
    assert {:ok, %{last_cursor: "next"}} = GatewayPull.pull(opts(store, dir))
    assert count(store, "accounting_events") == {:ok, [[5]]}
    Agent.stop(config)
  end

  test "lost real commit acknowledgement reloads on fresh lease then refetches", %{
    store: store,
    dir: dir
  } do
    owner = self()
    config = context(%{owner: owner, lose_ack: true})
    data = rows()

    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(owner, {:http, conn.params["cursor"], Agent.get(config, &{&1.leases, &1.releases})})
      Req.Test.json(conn, body(if(conn.params["cursor"], do: [], else: data), "next"))
    end)

    assert {:ok, %{last_cursor: "next"}} =
             GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))

    assert_receive {:http, nil, {1, 1}}
    assert_receive {:lost_ack, {:ok, _}, 2, 1}
    assert_receive {:http, "next", {3, 3}}
    assert count(store, "accounting_events") == {:ok, [[5]]}
    assert count(store, "ingest_ledger") == {:ok, [[2]]}
    Agent.stop(config)
  end

  test "three recovery retries means initial request plus three; exhaustion returns safe error",
       %{store: store, dir: dir} do
    owner = self()
    config = context(%{owner: owner, lose_ack: true, always_lose_ack: true})

    Req.Test.stub(GatewayPull, fn conn ->
      send(owner, :http)
      Req.Test.json(conn, body([], "empty"))
    end)

    assert {:error, %{code: :commit_uncertain}} =
             GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))

    for _ <- 1..4, do: assert_receive(:http)
    refute_receive :http
    assert Agent.get(config, &{&1.leases, &1.releases}) == {8, 8}
    assert {:ok, %{cursor: "empty"}} = AccountingStore.checkpoint(store, source())
    Agent.stop(config)
  end

  test "stale HTTP page is discarded and winner checkpoint is refetched", %{
    store: store,
    dir: dir
  } do
    owner = self()
    [a, b, c | _] = rows()

    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.params["cursor"] do
        nil ->
          send(owner, {:fetched, self()})

          receive do
            :respond -> :ok
          after
            5_000 -> flunk("HTTP barrier timed out")
          end

          Req.Test.json(conn, body([a], "stale"))

        "winner" ->
          Req.Test.json(conn, body([a], "fresh"))

        "fresh" ->
          Req.Test.json(conn, body([], "fresh"))
      end
    end)

    task = Task.async(fn -> GatewayPull.pull(opts(store, dir)) end)
    assert_receive {:fetched, worker}, 2_000
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:ok, _} =
             AccountingStore.ingest_page(store, receipt([b, c], nil, "winner"), {:advance, cp})

    send(worker, :respond)
    assert {:ok, %{last_cursor: "fresh"}} = Task.await(task)

    assert {:ok, %{booked_total_microdollars: 70}} =
             AccountingStore.get_state(
               store,
               source().source_id,
               a["virtual_key_id"],
               a["run_id"]
             )

    assert count(store, "accounting_events") == {:ok, [[3]]}

    assert {:ok, [[0]]} =
             Store.query(store, "SELECT count(*) FROM gateway_checkpoints WHERE cursor = 'stale'")
  end

  test "failed nested begin natively aborts its lease without an accounting rollback", %{
    store: store,
    dir: dir
  } do
    {:ok, _} = Store.query(store, "CREATE TABLE sentinel (id INTEGER PRIMARY KEY)")
    config = context(%{owner: self(), prebegin: true})
    default_http()
    {:ok, _} = Store.query(store, "BEGIN")
    {:ok, _} = Store.query(store, "INSERT INTO sentinel VALUES (99)")

    assert {:error, %{code: :storage_error}} =
             GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))

    assert {:ok, [[99]]} = Store.query(store, "SELECT * FROM sentinel")
    {:ok, _} = Store.query(store, "ROLLBACK")
    assert_receive {:before_nested, {:ok, [[71]]}}
    assert_receive {:sentinel, {:error, reason}}
    assert reason =~ "Current transaction is aborted"
    refute :rollback in Agent.get(config, & &1.commands)
    assert_empty(store)
    Agent.stop(config)
  end

  test "missing tables unrelated constraints and actual aborted commit remain storage errors", %{
    store: store,
    dir: dir
  } do
    default_http()
    {:ok, _} = Store.query(store, "CREATE TABLE sentinel (id INTEGER PRIMARY KEY)")
    config = context(%{owner: self(), abort_commit: true})

    assert {:error, %{code: :storage_error}} =
             GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))

    assert_empty(store)
    assert :commit in Agent.get(config, & &1.commands)
    Agent.stop(config)

    {:ok, _} =
      Store.query(store, "CREATE UNIQUE INDEX single_booking ON accounting_events (source_id)")

    assert {:error, %{code: :storage_error}} = GatewayPull.pull(opts(store, dir))
    assert_empty(store)
    {:ok, _} = Store.query(store, "DROP INDEX single_booking")
    {:ok, _} = Store.query(store, "DROP TABLE accounting_states")
    assert {:error, %{code: :storage_error}} = GatewayPull.pull(opts(store, dir))
    assert count(store, "gateway_checkpoints") == {:ok, [[0]]}
  end

  test "same-handle first-insert race leaves only winner before loser refetch", %{
    store: store,
    dir: dir
  } do
    owner = self()
    [a, b, c | _] = rows()
    config = context(%{owner: owner, pause: "INSERT INTO gateway_checkpoints"})

    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      Req.Test.json(
        conn,
        body(if(conn.params["cursor"], do: [], else: [a]), conn.params["cursor"] || "loser")
      )
    end)

    task =
      Task.async(fn ->
        GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))
      end)

    assert_receive {:paused, worker}, 2_000
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:ok, _} =
             AccountingStore.ingest_page(store, receipt([b, c], nil, "winner"), {:advance, cp})

    send(worker, :resume)
    assert {:ok, %{last_cursor: "winner"}} = Task.await(task)

    assert {:ok, ids} =
             Store.query(store, "SELECT event_id FROM accounting_events ORDER BY booking_version")

    assert ids == [[b["event_id"]], [c["event_id"]]]

    assert {:ok, %{booked_total_microdollars: nil}} =
             AccountingStore.get_state(
               store,
               source().source_id,
               a["virtual_key_id"],
               a["run_id"]
             )

    Agent.stop(config)
  end

  test "common cursor race loses without events and source checkpoints stay isolated", %{
    store: store,
    dir: dir
  } do
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:ok, _} =
             AccountingStore.ingest_page(store, receipt([], nil, "start"), {:advance, cp})

    owner = self()
    config = context(%{owner: owner, pause: "UPDATE gateway_checkpoints SET"})
    data = rows()
    Req.Test.stub(GatewayPull, fn conn -> Req.Test.json(conn, body(data, "next")) end)

    task =
      Task.async(fn ->
        GatewayPull.pull(opts(store, dir, db: {MimirAnalytics.GatewayRecoveryDB, config}))
      end)

    assert_receive {:paused, worker}, 2_000
    {:ok, cp} = AccountingStore.checkpoint(store, source())

    assert {:error, %{code: :storage_error}} =
             AccountingStore.ingest_page(store, receipt([], "start", "start"), {:advance, cp})

    assert count(store, "accounting_events") == {:ok, [[0]]}
    assert {:ok, %{cursor: nil}} = AccountingStore.checkpoint(store, source("other:issuer"))
    send(worker, :resume)
    assert {:error, %{code: :invalid_page}} = Task.await(task)
    assert count(store, "accounting_events") == {:ok, [[5]]}
    assert {:ok, %{cursor: "next"}} = AccountingStore.checkpoint(store, source())
    default_http()

    assert {:ok, %{last_cursor: "next"}} =
             GatewayPull.pull(opts(store, dir, source_id: "other:issuer"))

    assert count(store, "accounting_events") == {:ok, [[10]]}
    assert {:ok, %{cursor: "next"}} = AccountingStore.checkpoint(store, source("other:issuer"))
    assert {:ok, %{cursor: "next"}} = AccountingStore.checkpoint(store, source())
    Agent.stop(config)
  end

  test "reopen after committed file loss resumes durable position; CLI ignores dot temporaries",
       %{store: store, dir: dir} do
    # Reopen uses a separate owned file so fixture cleanup never closes an obsolete handle.
    path = Path.join(dir, "restart.duckdb")
    {:ok, first} = Store.open(path)
    default_http()
    assert {:ok, %{files: files}} = GatewayPull.pull(opts(first, dir))
    Store.close(first)
    Enum.each(files, &File.rm!/1)
    {:ok, reopened} = Store.open(path)

    try do
      owner = self()

      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(owner, {:restart_cursor, conn.params["cursor"]})
        Req.Test.json(conn, body([], "next"))
      end)

      assert {:ok, _} = GatewayPull.pull(opts(reopened, dir))
      assert_receive {:restart_cursor, "next"}
      assert count(reopened, "accounting_events") == {:ok, [[5]]}
    after
      Store.close(reopened)
    end

    buffers = Path.join(dir, "buffers")
    File.write!(Path.join(buffers, ".incomplete.jsonl"), "broken-secret")

    output =
      capture_io(fn ->
        Ingest.run([
          "--db",
          Path.join(dir, "cli.duckdb"),
          "--gateway",
          buffers
        ])
      end)

    assert output =~ "gateway: 1"
    assert File.exists?(Path.join(buffers, ".incomplete.jsonl"))
    assert length(Path.wildcard(Path.join(buffers, "*.jsonl"))) == 1
    assert_empty(store)
  end
end
