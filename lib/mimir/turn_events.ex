defmodule Mimir.TurnEvents do
  @moduledoc """
  Per-request ordered `gen_ai.*` event buffer.

  Two ETS tables: a seq counter and an ordered-set event store, both keyed
  by a request id. Table names default to `:mimir_turn_seq` /
  `:mimir_turn_events` and are configurable via `:mimir, :turn_events_tables`
  (a `{seq_table, buf_table}` tuple) — set this if an embedder needs to run
  more than one buffer instance side by side.

  The "current" request id is held in the process dictionary; the embedder
  sets it (`put_current/1`) at the start of a request, telemetry handlers and
  the embedder append under it (`append_current/2`), and the embedder drains
  the buffer with `take/1` (or `take_current/0`) when it meters the request.

  A TTL sweep reclaims buffers orphaned by a crashed request.
  """
  use GenServer

  @pdkey {__MODULE__, :rid}
  @ttl_ns 120_000_000_000
  @sweep_interval_ms 60_000

  @type request_id :: String.t() | integer()

  defp seq_table, do: elem(tables(), 0)
  defp buf_table, do: elem(tables(), 1)

  defp tables,
    do: Application.get_env(:mimir, :turn_events_tables, {:mimir_turn_seq, :mimir_turn_events})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Set the process-local current request id (the buffer key)."
  @spec put_current(request_id() | any()) :: :ok
  def put_current(rid) when is_binary(rid) or is_integer(rid), do: Process.put(@pdkey, rid)
  def put_current(_), do: :ok

  @doc "The process-local current request id, or nil."
  @spec current() :: request_id() | nil
  def current, do: Process.get(@pdkey)

  @doc "Append one event under `rid`. No-op for a nil id. Never raises."
  @spec append(request_id() | nil, String.t() | atom(), map()) :: :ok
  def append(nil, _type, _gen_ai), do: :ok

  def append(rid, type, gen_ai) when is_map(gen_ai) do
    seq =
      :ets.update_counter(
        seq_table(),
        rid,
        {2, 1},
        {rid, 0, System.monotonic_time(:nanosecond)}
      )

    :ets.insert(
      buf_table(),
      {{rid, seq}, System.monotonic_time(:nanosecond), to_string(type), gen_ai}
    )

    :ok
  rescue
    _ -> :ok
  end

  def append(_rid, _type, _gen_ai), do: :ok

  @doc "Append under the process-current id."
  @spec append_current(String.t() | atom(), map()) :: :ok
  def append_current(type, gen_ai), do: append(current(), type, gen_ai)

  @doc """
  The persisted event envelope — the single source of the shape stored by
  callers that persist `gen_ai` events (e.g. a route log) and returned by
  `take/1`. Anything writing an event row outside the buffer builds it here
  so the envelope vocabulary cannot fork.
  """
  @spec envelope(non_neg_integer(), integer(), String.t() | atom(), map()) :: map()
  def envelope(seq, ts, type, gen_ai) when is_map(gen_ai) do
    %{"seq" => seq, "ts" => ts, "type" => to_string(type), "gen_ai" => gen_ai}
  end

  @doc "Take (and clear) the seq-ordered event list for `rid`."
  @spec take(request_id() | nil) :: [map()]
  def take(nil), do: []

  def take(rid) do
    spec = [{{{rid, :"$1"}, :"$2", :"$3", :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}]
    rows = :ets.select(buf_table(), spec)
    :ets.match_delete(buf_table(), {{rid, :_}, :_, :_, :_})
    :ets.delete(seq_table(), rid)

    rows
    |> Enum.sort_by(fn {seq, _ts, _type, _g} -> seq end)
    |> Enum.map(fn {seq, ts, type, g} -> envelope(seq, ts, type, g) end)
  rescue
    _ -> []
  end

  @doc "Take the current id's list and clear the current id."
  @spec take_current() :: [map()]
  def take_current do
    rid = current()
    Process.delete(@pdkey)
    take(rid)
  end

  @impl true
  def init(_opts) do
    :ets.new(seq_table(), [:named_table, :public, :set, read_concurrency: true])

    :ets.new(buf_table(), [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:nanosecond) - @ttl_ns
    :ets.select_delete(buf_table(), [{{:_, :"$1", :_, :_}, [{:<, :"$1", cutoff}], [true]}])
    :ets.select_delete(seq_table(), [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
