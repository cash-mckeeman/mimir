defmodule MimirAnalytics.AccountingTestDB do
  @moduledoc false
  @behaviour MimirAnalytics.Store.DB
  alias MimirAnalytics.Store
  alias MimirAnalytics.Store.{DB, DuckDB}

  @impl true
  @spec lease(Store.t(), pid()) :: {:ok, Store.t()} | {:error, :unavailable}
  def lease(store, context) do
    result = DuckDB.lease(store, nil)
    Agent.update(context, &Map.update!(&1, :leases, fn n -> n + 1 end))

    case result do
      {:ok, lease} ->
        if Agent.get(context, &Map.get(&1, :prebegin, false)),
          do: DuckDB.command(lease, :begin, nil)

      _ ->
        :ok
    end

    result
  end

  @impl true
  @spec release(Store.t(), pid()) :: :ok
  def release(store, context) do
    result = DuckDB.release(store, nil)
    Agent.update(context, &Map.update!(&1, :releases, fn n -> n + 1 end))
    result
  end

  @impl true
  @spec command(Store.t(), DB.command(), pid()) :: {:ok, [[term()]]} | {:error, DB.failure()}
  def command(store, cmd, context) do
    result = DuckDB.command(store, cmd, nil)
    Agent.update(context, &Map.update(&1, :commands, [cmd], fn commands -> [cmd | commands] end))
    config = Agent.get(context, & &1)
    maybe_pause(cmd, result, config)
    if cmd == :commit and config.lose_commit_ack, do: {:error, :unavailable}, else: result
  end

  defp maybe_pause({:query, sql, _}, {:ok, [[_]]}, %{pause_owner: owner} = config)
       when is_pid(owner) do
    prefixes =
      Map.get(config, :pause_prefixes, [
        "UPDATE gateway_checkpoints SET",
        "INSERT INTO gateway_checkpoints"
      ])

    if Enum.any?(prefixes, &String.starts_with?(sql, &1)) do
      send(owner, {:cas_written, self()})

      receive do
        :continue_commit -> :ok
      after
        5_000 -> raise "accounting test CAS barrier timed out"
      end
    end
  end

  defp maybe_pause(_, _, _), do: :ok
end
