defmodule MimirAnalytics.Schema do
  @moduledoc """
  Canonical run-record DDL. Tables are created if absent, then missing
  columns are added to existing tables. `apply/1` is idempotent.

  Column additions to existing tables need an entry in `@column_migrations`;
  `CREATE TABLE IF NOT EXISTS` alone does not change their columns.
  """

  @tables ~w(workflow_runs steps runs turns tool_calls model_calls routing_decisions eval_outcomes events_raw memory_provenance ingest_ledger ingest_rejections)

  # One entry per column added to a table after that table's first release.
  # `priv/schema.sql`'s `CREATE TABLE IF NOT EXISTS runs (...)` already lists
  # `outcome` for a database created fresh from today's schema; this
  # statement is what brings an OLDER database's `runs` table up to date.
  @column_migrations [
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
  """
  @spec apply(reference()) :: :ok | {:error, :name_keyed_ledger}
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
