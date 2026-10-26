defmodule MimirAnalytics.AccountingStore do
  @moduledoc "Atomic accounting history, ingest receipts and source checkpoint acknowledgement."
  alias MimirAnalytics.Accounting.{Checkpoint, Error, Event, Fold, Page, Source, State}
  alias MimirAnalytics.{Mapper, Store}
  alias MimirAnalytics.Store.DuckDB

  @type options :: [db: {module(), pid() | nil}]
  @type mode :: :replay | {:advance, Checkpoint.t()}
  @spec ingest_page(Store.t(), Page.t(), mode(), options()) ::
          {:ok, Mapper.summary()} | :already_ingested | {:error, Error.t()}
  def ingest_page(store, page, mode, opts \\ [])

  def ingest_page(store, %Page{digest: digest, source_file: file} = page, mode, opts)
      when is_binary(digest) and is_binary(file) do
    with :ok <- expectation(page, mode) do
      result = leased(store, opts, &ingest_transaction(&1, &2, page, mode))
      resolve_native_abort(store, page, mode, opts, result)
    end
  end

  def ingest_page(_, _, _, _), do: Error.result(:invalid_page)

  @spec checkpoint(Store.t(), Source.t(), options()) ::
          {:ok, Checkpoint.t()} | {:error, Error.t()}
  def checkpoint(store, %Source{} = source, opts \\ []) do
    leased(store, opts, fn lease, adapter ->
      case query!(
             lease,
             adapter,
             "SELECT source_id, api_version, endpoint, cursor, page_digest FROM gateway_checkpoints WHERE source_id = ? AND api_version = ?",
             [source.source_id, 2]
           ) do
        [] -> checkpoint_new(source.source_id, nil, nil)
        [row] -> persisted_checkpoint(row)
      end
    end)
  end

  @spec get_state(Store.t(), String.t(), String.t(), String.t(), options()) ::
          {:ok, State.t()} | :miss | {:error, Error.t()}
  def get_state(store, source_id, key_id, run_id, opts \\ []) do
    leased(store, opts, fn lease, adapter ->
      state(lease, adapter, [source_id, key_id, run_id])
    end)
  end

  defp persisted_checkpoint([id, 2, "accounting", cursor, digest])
       when is_binary(cursor) and is_binary(digest) do
    case checkpoint_new(id, cursor, digest) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, _} -> Error.result(:storage_error)
    end
  end

  defp persisted_checkpoint(_), do: Error.result(:storage_error)

  defp resolve_native_abort(
         store,
         page,
         {:advance, expected},
         opts,
         {:native_transaction_abort, _}
       ) do
    case checkpoint(store, page.source, opts) do
      {:ok, ^expected} -> Error.result(:storage_error)
      {:ok, %Checkpoint{}} -> Error.result(:checkpoint_conflict)
      {:error, _} = error -> error
    end
  end

  defp resolve_native_abort(_store, _page, :replay, _opts, {:native_transaction_abort, _}),
    do: Error.result(:storage_error)

  defp resolve_native_abort(_store, _page, _mode, _opts, result), do: result

  defp checkpoint_new(id, cursor, digest),
    do:
      Checkpoint.new(%{
        source_id: id,
        api_version: 2,
        endpoint: :accounting,
        cursor: cursor,
        page_digest: digest
      })

  defp expectation(_page, :replay), do: :ok

  defp expectation(page, {:advance, %Checkpoint{} = cp}) do
    with {:ok, ^cp} <- Checkpoint.new(Map.from_struct(cp)),
         true <-
           cp.source_id == page.source.source_id and cp.api_version == page.source.api_version and
             cp.cursor == page.from_cursor do
      :ok
    else
      _ -> Error.result(:checkpoint_conflict)
    end
  end

  defp expectation(_, _), do: Error.result(:checkpoint_conflict)

  defp leased(store, opts, fun) do
    {module, context} = adapter = Keyword.get(opts, :db, {DuckDB, nil})

    case module.lease(store, context) do
      {:ok, lease} ->
        try do
          fun.(lease, adapter)
        catch
          {:accounting_db, _reason} -> Error.result(:storage_error)
        after
          module.release(lease, context)
        end

      {:error, :unavailable} ->
        Error.result(:storage_error)
    end
  end

  defp ingest_transaction(store, adapter, page, mode),
    do: transaction(store, adapter, fn -> ingest(store, adapter, page, mode) end)

  defp transaction(store, adapter, fun) do
    case command(store, adapter, :begin) do
      {:ok, _} -> owned_transaction(store, adapter, fun)
      {:error, _} -> Error.result(:storage_error)
    end
  end

  defp owned_transaction(store, adapter, fun) do
    result =
      try do
        case fun.() do
          {:error, _} = error ->
            command(store, adapter, :rollback)
            error

          result ->
            {:commit, result}
        end
      rescue
        exception ->
          command(store, adapter, :rollback)
          reraise exception, __STACKTRACE__
      catch
        :throw, {:accounting_db, reason} when reason in [:conflict, :constraint] ->
          command(store, adapter, :rollback)
          {:native_transaction_abort, reason}

        kind, reason ->
          command(store, adapter, :rollback)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      {:commit, value} ->
        case command(store, adapter, :commit) do
          {:ok, _} ->
            value

          {:error, reason} when reason in [:conflict, :constraint] ->
            {:native_transaction_abort, reason}

          {:error, :unavailable} ->
            Error.result(:commit_uncertain)
        end

      error ->
        error
    end
  end

  defp command(store, {module, context}, cmd), do: module.command(store, cmd, context)

  defp query!(store, adapter, sql, params) do
    case command(store, adapter, {:query, sql, params}) do
      {:ok, rows} -> rows
      {:error, reason} -> throw({:accounting_db, reason})
    end
  end

  defp ingest(store, adapter, page, mode) do
    with :ok <- advance(store, adapter, page, mode) do
      ledger =
        query!(store, adapter, "SELECT 1 FROM ingest_ledger WHERE digest = ?", [page.digest])

      ingest_unledgered(store, adapter, page, mode, ledger)
    end
  end

  defp ingest_unledgered(_store, _adapter, _page, :replay, [_ | _]), do: :already_ingested
  defp ingest_unledgered(_store, _adapter, _page, {:advance, _}, [_ | _]), do: summary(0, 0)

  defp ingest_unledgered(store, adapter, page, _mode, []) do
    with {:ok, count, keys} <- insert_events(store, adapter, page.events),
         {:ok, changed} <- fold_states(store, adapter, keys) do
      query!(
        store,
        adapter,
        "INSERT INTO ingest_ledger (digest, source_file, source, ingested_at, rows) VALUES (?, ?, ?, now(), ?)",
        [page.digest, page.source_file, "gateway_accounting", count]
      )

      summary(count, changed)
    end
  end

  defp summary(events, states),
    do: {:ok, %{rows: %{"accounting_events" => events, "accounting_states" => states}}}

  defp advance(_, _, _, :replay), do: :ok

  defp advance(store, adapter, page, {:advance, cp}) do
    {sql, params} =
      if is_nil(cp.cursor) do
        {"INSERT INTO gateway_checkpoints (source_id, api_version, endpoint, cursor, page_digest) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING RETURNING source_id",
         [cp.source_id, 2, "accounting", page.next_cursor, page.digest]}
      else
        {"UPDATE gateway_checkpoints SET cursor = ?, page_digest = ? WHERE source_id = ? AND api_version = ? AND endpoint = ? AND cursor IS NOT DISTINCT FROM ? AND page_digest IS NOT DISTINCT FROM ? RETURNING source_id",
         [page.next_cursor, page.digest, cp.source_id, 2, "accounting", cp.cursor, cp.page_digest]}
      end

    case command(store, adapter, {:query, sql, params}) do
      {:ok, [[_]]} -> :ok
      {:ok, []} -> Error.result(:checkpoint_conflict)
      {:error, reason} -> throw({:accounting_db, reason})
    end
  end

  defp insert_events(store, adapter, events) do
    Enum.reduce_while(events, {:ok, 0, MapSet.new()}, fn event, {:ok, count, keys} ->
      case insert_event(store, adapter, event) do
        :existing ->
          {:cont, {:ok, count, keys}}

        :inserted ->
          {:cont,
           {:ok, count + 1,
            MapSet.put(keys, {event.source_id, event.virtual_key_id, event.run_id})}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp insert_event(store, adapter, event) do
    fingerprint = Event.fingerprint(event)

    existing =
      query!(
        store,
        adapter,
        "SELECT fingerprint FROM accounting_events WHERE source_id = ? AND event_id = ?",
        [event.source_id, event.event_id]
      )

    case existing do
      [[^fingerprint]] -> :existing
      [[_]] -> Error.result(:event_conflict)
      [] -> insert_version(store, adapter, event, fingerprint)
    end
  end

  defp insert_version(store, adapter, event, fingerprint) do
    params = [event.source_id, event.virtual_key_id, event.run_id, event.booking_version]

    case query!(
           store,
           adapter,
           "SELECT event_id FROM accounting_events WHERE source_id = ? AND virtual_key_id = ? AND run_id = ? AND booking_version = ?",
           params
         ) do
      [[_]] ->
        Error.result(:booking_conflict)

      [] ->
        query!(
          store,
          adapter,
          "INSERT INTO accounting_events (source_id, event_id, virtual_key_id, run_id, booking_version, fingerprint, event_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            event.source_id,
            event.event_id,
            event.virtual_key_id,
            event.run_id,
            event.booking_version,
            fingerprint,
            Jason.encode!(Event.to_wire(event))
          ]
        )

        :inserted
    end
  end

  defp fold_states(store, adapter, keys) do
    Enum.reduce_while(keys, {:ok, 0}, fn key, {:ok, changed} ->
      case fold_state(store, adapter, Tuple.to_list(key)) do
        {:ok, count} -> {:cont, {:ok, changed + count}}
        error -> {:halt, error}
      end
    end)
  end

  defp fold_state(store, adapter, [id, _, _] = params) do
    rows =
      query!(
        store,
        adapter,
        "SELECT event_json FROM accounting_events WHERE source_id = ? AND virtual_key_id = ? AND run_id = ? ORDER BY booking_version",
        params
      )

    with {:ok, source} <- Source.new(%{source_id: id, api_version: 2}),
         {:ok, events} <- decode_events(rows, source),
         {:ok, folded} <- Fold.build(events) do
      update_state(store, adapter, params, folded)
    end
  end

  defp update_state(store, adapter, params, folded) do
    case state(store, adapter, params) do
      {:ok, ^folded} ->
        {:ok, 0}

      {:error, _} = error ->
        error

      _ ->
        write_state(store, adapter, params, folded)
        {:ok, 1}
    end
  end

  defp decode_events(rows, source) do
    Enum.reduce_while(rows, {:ok, []}, fn [json], {:ok, events} ->
      with {:ok, wire} <- Jason.decode(json), {:ok, event} <- Event.new(wire, source) do
        {:cont, {:ok, [event | events]}}
      else
        _ -> {:halt, Error.result(:storage_error)}
      end
    end)
  end

  defp state(store, adapter, [id, _, _] = params) do
    case query!(
           store,
           adapter,
           "SELECT latest_json, missing_ranges, booked_total_microdollars FROM accounting_states WHERE source_id = ? AND virtual_key_id = ? AND run_id = ?",
           params
         ) do
      [] ->
        :miss

      [row] ->
        decode_state(id, row)
    end
  end

  defp decode_state(id, [json, ranges_json, total]) do
    with {:ok, source} <- Source.new(%{source_id: id, api_version: 2}),
         {:ok, [latest]} <- decode_events([[json]], source),
         {:ok, ranges} <- Jason.decode(ranges_json) do
      State.new(%{
        latest: latest,
        original_period: latest.budget_period_start,
        history: history(ranges),
        booked_total_microdollars: total
      })
    else
      _ -> Error.result(:storage_error)
    end
  end

  defp history([]), do: :complete

  defp history(ranges),
    do: {:missing_versions, Enum.map(ranges, fn [a, b] -> Range.new(a, b) end)}

  defp write_state(store, adapter, params, state) do
    ranges =
      case state.history do
        :complete -> []
        {:missing_versions, ranges} -> Enum.map(ranges, fn r -> [r.first, r.last] end)
      end

    query!(
      store,
      adapter,
      "INSERT INTO accounting_states (source_id, virtual_key_id, run_id, original_period, latest_json, missing_ranges, booked_total_microdollars, priceability, charge_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (source_id, virtual_key_id, run_id) DO UPDATE SET original_period = excluded.original_period, latest_json = excluded.latest_json, missing_ranges = excluded.missing_ranges, booked_total_microdollars = excluded.booked_total_microdollars, priceability = excluded.priceability, charge_state = excluded.charge_state",
      params ++
        [
          state.original_period,
          Jason.encode!(Event.to_wire(state.latest)),
          Jason.encode!(ranges),
          state.booked_total_microdollars,
          Atom.to_string(state.latest.priceability),
          Atom.to_string(state.latest.charge_state)
        ]
    )
  end
end
