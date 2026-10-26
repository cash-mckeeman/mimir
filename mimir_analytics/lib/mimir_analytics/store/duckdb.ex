defmodule MimirAnalytics.Store.DuckDB do
  @moduledoc "Accounting connections leased from a caller-owned DuckDB handle."
  @behaviour MimirAnalytics.Store.DB
  alias MimirAnalytics.Store
  alias MimirAnalytics.Store.DB
  @impl true
  @spec lease(Store.t(), DB.context()) :: {:ok, Store.t()} | {:error, :unavailable}
  def lease(%Store{db: db} = store, _context) do
    case Duckdbex.connection(db) do
      {:ok, conn} -> {:ok, %{store | conn: conn}}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  @spec release(Store.t(), DB.context()) :: :ok
  def release(%Store{conn: conn}, _context), do: Duckdbex.release(conn)
  @impl true
  @spec command(Store.t(), DB.command(), DB.context()) ::
          {:ok, [[term()]]} | {:error, DB.failure()}
  def command(store, :commit, _context) do
    health = execute(store, "SELECT 1", [])
    commit = execute(store, "COMMIT", [])

    case health do
      {:ok, _} -> commit
      {:error, _} = error -> error
    end
  end

  def command(store, command, _context) do
    {sql, params} = sql(command)
    execute(store, sql, params)
  end

  defp execute(store, sql, params) do
    case Store.query(store, sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, classify(reason)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp sql(:begin), do: {"BEGIN TRANSACTION", []}
  defp sql(:rollback), do: {"ROLLBACK", []}
  defp sql({:query, sql, params}), do: {sql, params}

  defp classify(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "TransactionContext Error") or
        String.contains?(reason, "Transaction conflict") or
          String.contains?(reason, "Conflict on") ->
        :conflict

      String.contains?(reason, "Constraint Error") ->
        :constraint

      true ->
        :unavailable
    end
  end

  defp classify(_), do: :unavailable
end
