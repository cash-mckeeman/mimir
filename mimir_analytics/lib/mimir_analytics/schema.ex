defmodule MimirAnalytics.Schema do
  @moduledoc """
  Canonical run-record DDL. Tables are created if absent, then missing
  columns are added to existing tables. `apply/1` is idempotent.

  Column additions to existing tables need an entry in `@column_migrations`;
  `CREATE TABLE IF NOT EXISTS` alone does not change their columns.
  """

  @tables ~w(workflow_runs steps runs turns tool_calls model_calls routing_decisions eval_outcomes events_raw memory_provenance ingest_ledger ingest_rejections accounting_events accounting_states gateway_checkpoints accounting_audits accounting_event_ids)

  # One entry per column added to a table after that table's first release.
  # `priv/schema.sql`'s `CREATE TABLE IF NOT EXISTS runs (...)` already lists
  # `outcome` for a database created fresh from today's schema; this
  # statement is what brings an OLDER database's `runs` table up to date.
  @column_migrations [
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS cache_read_input_tokens BIGINT",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS cache_creation_input_tokens BIGINT",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS input_token_basis TEXT",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS usage_complete BOOLEAN",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS in_flight TEXT",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS outcome TEXT",
    "ALTER TABLE runs ADD COLUMN IF NOT EXISTS error_class TEXT",
    "ALTER TABLE events_raw ADD COLUMN IF NOT EXISTS domain TEXT",
    "ALTER TABLE events_raw ADD COLUMN IF NOT EXISTS ce_id TEXT",
    "ALTER TABLE events_raw ADD COLUMN IF NOT EXISTS ce_source TEXT",
    "ALTER TABLE events_raw ADD COLUMN IF NOT EXISTS ce_type TEXT"
  ]

  @spec tables() :: [String.t()]
  def tables, do: @tables

  @doc """
  Create every table, then add any columns an older database lacks.

  Returns `{:error, :name_keyed_ledger}`, changing nothing, when the database
  holds an `ingest_ledger` from before the ledger was keyed by content
  digest. Its entries name files, not contents, so they cannot tell whether a
  file that has since grown was fully read. Such a database is rebuilt, not
  migrated: delete it and re-ingest the source directories (README,
  "Upgrading a database").

  Financial event identities are backfilled without changing history; a retained
  registry mismatch returns `{:error, :accounting_identity_conflict}`.
  """
  @spec apply(reference()) :: :ok | {:error, :name_keyed_ledger | :accounting_identity_conflict}
  def apply(conn) do
    # JSON columns need the json extension and now()/date_trunc() live in
    # core_functions. LOAD reads from the local extension directory
    # (~/.duckdb/extensions) — provisioned once per machine/CI runner via
    # `mix mimir_analytics.setup` (network), so tests stay offline.
    {:ok, _} = Duckdbex.query(conn, "LOAD json")
    {:ok, _} = Duckdbex.query(conn, "LOAD core_functions")

    if name_keyed_ledger?(conn) do
      {:error, :name_keyed_ledger}
    else
      create(conn)
      backfill_accounting_ids(conn)
    end
  end

  defp create(conn) do
    :mimir_analytics
    |> :code.priv_dir()
    |> Path.join("schema.sql")
    |> File.read!()
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn stmt ->
      {:ok, _} = Duckdbex.query(conn, stmt)
    end)

    Enum.each(@column_migrations, fn stmt ->
      {:ok, _} = Duckdbex.query(conn, stmt)
    end)
  end

  defp backfill_accounting_ids(conn) do
    {:ok, _} = Duckdbex.query(conn, "BEGIN")

    result =
      with {:ok, ref} <-
             Duckdbex.query(
               conn,
               "SELECT count(*) FROM accounting_events e JOIN accounting_event_ids i USING (source_id,event_id) WHERE i.fingerprint IS DISTINCT FROM e.fingerprint OR i.kind IS DISTINCT FROM (e.event_json->>'kind')"
             ),
           [[0]] <- Duckdbex.fetch_all(ref),
           {:ok, _} <-
             Duckdbex.query(
               conn,
               "INSERT INTO accounting_event_ids SELECT source_id,event_id,event_json->>'kind',fingerprint FROM accounting_events e WHERE NOT EXISTS (SELECT 1 FROM accounting_event_ids i WHERE i.source_id = e.source_id AND i.event_id = e.event_id)"
             ),
           {:ok, _} <- Duckdbex.query(conn, "COMMIT") do
        :ok
      else
        _ -> {:error, :accounting_identity_conflict}
      end

    if result != :ok, do: Duckdbex.query(conn, "ROLLBACK")
    result
  end

  defp name_keyed_ledger?(conn) do
    {:ok, ref} =
      Duckdbex.query(
        conn,
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_catalog = current_database() AND table_schema = current_schema()
          AND table_name = 'ingest_ledger'
        """
      )

    case ref |> Duckdbex.fetch_all() |> List.flatten() do
      [] -> false
      columns -> "digest" not in columns
    end
  end
end
