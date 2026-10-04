defmodule MimirAnalytics.Store do
  @moduledoc """
  DuckDB run-record store for local files or MotherDuck databases. Inserts
  accept structs and derive SQL columns from their fields.

  `transaction/2` commits successful results and rolls back errors or
  exceptions, keeping source rows and their ingest-ledger entry atomic.
  """

  defstruct [:db, :conn]
  @type t :: %__MODULE__{db: reference(), conn: reference()}
  @type target :: :memory | Path.t() | {:motherduck, String.t()}

  @spec open(target()) :: {:ok, t()} | {:error, term()}
  def open(:memory), do: do_open(":memory:")

  # MotherDuck reads MOTHERDUCK_TOKEN from the environment. Database
  # provisioning options remain the caller's responsibility.
  def open({:motherduck, db_name}) when is_binary(db_name) do
    _token = motherduck_token!()

    with {:ok, db} <- Duckdbex.open(":memory:"),
         {:ok, conn} <- Duckdbex.connection(db),
         {:ok, _} <- Duckdbex.query(conn, "ATTACH 'md:'"),
         {:ok, _} <- Duckdbex.query(conn, "CREATE DATABASE IF NOT EXISTS #{db_name}"),
         {:ok, _} <- Duckdbex.query(conn, "USE #{db_name}"),
         :ok <- MimirAnalytics.Schema.apply(conn) do
      {:ok, %__MODULE__{db: db, conn: conn}}
    end
  end

  def open(path) when is_binary(path), do: do_open(path)

  # An empty token does not error — the
  # motherduck extension falls back to interactive browser auth and blocks
  # the dirty NIF indefinitely. Never ATTACH without a non-empty token.
  defp motherduck_token! do
    case System.get_env("MOTHERDUCK_TOKEN", "") |> String.trim() do
      "" ->
        raise "MOTHERDUCK_TOKEN is unset or empty — refusing to ATTACH " <>
                "(an empty token silently falls back to interactive browser " <>
                "auth and hangs the NIF)"

      token ->
        token
    end
  end

  defp do_open(target) do
    with {:ok, db} <- Duckdbex.open(target),
         {:ok, conn} <- Duckdbex.connection(db) do
      store = %__MODULE__{db: db, conn: conn}

      case MimirAnalytics.Schema.apply(conn) do
        :ok ->
          {:ok, store}

        {:error, _} = error ->
          :ok = close(store)
          error
      end
    end
  end

  @doc """
  Close the connection and the database now, rather than whenever the
  garbage collector reaches them. DuckDB writes its log back into the
  database file as it closes, so a second instance opened on the same file
  in the same OS process must not overlap the first one's close. The store
  cannot be used afterwards.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{db: db, conn: conn}) do
    :ok = Duckdbex.release(conn)
    :ok = Duckdbex.release(db)
  end

  @spec query(t(), String.t(), list()) :: {:ok, [[term()]]} | {:error, term()}
  def query(%__MODULE__{conn: conn}, sql, params \\ []) do
    result =
      case params do
        [] -> Duckdbex.query(conn, sql)
        _ -> Duckdbex.query(conn, sql, params)
      end

    case result do
      {:ok, ref} -> {:ok, Duckdbex.fetch_all(ref)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The ledger key for a source file's contents: the hex sha256 of its bytes.

  The ledger is keyed by content, not by name, because a producer can reuse
  a file name for different contents, and a name match would skip the new
  contents silently.
  """
  @spec digest(binary()) :: String.t()
  def digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc "Whether contents with `digest` were already ingested, under any file name."
  @spec ingested?(t(), String.t()) :: boolean()
  def ingested?(store, digest) do
    {:ok, rows} = query(store, "SELECT 1 FROM ingest_ledger WHERE digest = ?", [digest])
    rows != []
  end

  @doc "Whether a file named `source_file` was ingested from `source`, with any contents."
  @spec ingested_name?(t(), String.t(), String.t()) :: boolean()
  def ingested_name?(store, source, source_file) do
    {:ok, rows} =
      query(store, "SELECT 1 FROM ingest_ledger WHERE source = ? AND source_file = ?", [
        source,
        source_file
      ])

    rows != []
  end

  @doc "Whether contents with `digest` were already rejected, under any file name."
  @spec rejected?(t(), String.t()) :: boolean()
  def rejected?(store, digest) do
    {:ok, rows} = query(store, "SELECT 1 FROM ingest_rejections WHERE digest = ?", [digest])
    rows != []
  end

  @doc """
  Record that contents with `digest` were rejected for `reason`, so a file
  that is left in place is reported once per distinct contents, not on every
  run.
  """
  @spec record_rejection(t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def record_rejection(store, digest, source_file, source, reason) do
    case query(
           store,
           "INSERT INTO ingest_rejections (digest, source_file, source, reason, rejected_at) VALUES (?, ?, ?, ?, now())",
           [digest, source_file, source, reason]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
    end
  end

  @spec record_ingest(t(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def record_ingest(store, digest, source_file, source, rows) do
    case query(
           store,
           "INSERT INTO ingest_ledger (digest, source_file, source, ingested_at, rows) VALUES (?, ?, ?, now(), ?)",
           [digest, source_file, source, rows]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
    end
  end

  # Wraps `fun` in a DuckDB transaction: BEGIN before, COMMIT on `{:ok, _}`,
  # ROLLBACK on `{:error, _}` or on an exception (re-raised after rollback so
  # the transaction never leaks into an uncommitted, un-rolled-back state).
  # Callers wrap a file's inserts AND its ledger write in one call so a
  # mid-batch failure (a DB constraint error, e.g. a PK collision) leaves
  # zero rows and zero ledger entries — the retry then sees `ingested?/2 ==
  # false` and starts clean.
  @spec transaction(t(), (t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(%__MODULE__{conn: conn} = store, fun) do
    {:ok, _} = Duckdbex.query(conn, "BEGIN TRANSACTION")

    try do
      case fun.(store) do
        {:ok, _} = ok ->
          {:ok, _} = Duckdbex.query(conn, "COMMIT")
          ok

        {:error, _} = err ->
          {:ok, _} = Duckdbex.query(conn, "ROLLBACK")
          err
      end
    rescue
      exception ->
        Duckdbex.query(conn, "ROLLBACK")
        reraise exception, __STACKTRACE__
    end
  end

  @spec insert(t(), String.t(), [struct()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert(_store, _table, []), do: {:ok, 0}

  def insert(%__MODULE__{} = store, table, [%mod{} | _] = rows) do
    # Column set + order come from the struct definition itself — every row
    # already carries exactly these fields (Elixir raises building any
    # struct with an unknown/missing-required key), so there's nothing left
    # to validate here. Sorted for a deterministic SQL statement.
    fields = mod |> struct() |> Map.from_struct() |> Map.keys() |> Enum.sort()
    insert_rows(store, table, fields, rows)
  end

  defp insert_rows(%__MODULE__{conn: conn}, table, fields, rows) do
    col_list = Enum.map_join(fields, ", ", &Atom.to_string/1)
    placeholders = Enum.map_join(fields, ", ", fn _ -> "?" end)
    sql = "INSERT INTO #{table} (#{col_list}) VALUES (#{placeholders})"

    Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, n} ->
      params = Enum.map(fields, fn f -> row |> Map.fetch!(f) |> encode() end)

      case Duckdbex.query(conn, sql, params) do
        {:ok, _} -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, {:insert_failed, table, reason}}}
      end
    end)
  end

  defp encode(v) when is_map(v) or is_list(v), do: Jason.encode!(v)
  defp encode(v), do: v
end
