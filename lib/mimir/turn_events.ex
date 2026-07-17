defmodule Mimir.TurnEvents do
  @moduledoc """
  Per-request ordered `Mimir.Event` buffer.

  Two ETS tables: a seq counter and an ordered-set event store, both keyed
  by a request id. Table names default to `:mimir_turn_seq` /
  `:mimir_turn_events` and are configurable via `:mimir, :turn_events_tables`
  (a `{seq_table, buf_table}` tuple) — set this if an embedder needs to run
  more than one buffer instance side by side.

  The "current" request id is held in the process dictionary; the embedder
  sets it (`put_current/1`) at the start of a request, telemetry handlers and
  the embedder append under it (`append_current/1`), and the embedder drains
  the buffer with `take/1` (or `take_current/0`) when it meters the request.

  **The buffer owns `seq`/`ts`, not the caller.** `append/2` accepts the
  caller's `%Mimir.Event{}` as-given, but stamps it with the request's next
  1-based insertion-order `seq` and the append-time monotonic `ts` before
  storing it — whatever `seq`/`ts` the caller's constructor set is
  overwritten. `take/1`/`take_current/0` return events in that
  buffer-assigned seq order, carrying the buffer-assigned `seq`/`ts`.

  A TTL sweep reclaims buffers orphaned by a crashed request.
  """
  use GenServer

  alias Mimir.Event

  @pdkey {__MODULE__, :rid}
  @ttl_ns 120_000_000_000
  @sweep_interval_ms 60_000

  @type request_id :: String.t() | integer()

  defp seq_table, do: elem(tables(), 0)
  defp buf_table, do: elem(tables(), 1)

  defp tables,
    do: Application.get_env(:mimir, :turn_events_tables, {:mimir_turn_seq, :mimir_turn_events})

  @doc "Start the buffer's table owner. `opts` are unused; accepted for supervision-tree conformance."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Set the process-local current request id (the buffer key)."
  @spec put_current(request_id() | any()) :: :ok
  def put_current(rid) when is_binary(rid) or is_integer(rid) do
    Process.put(@pdkey, rid)
    :ok
  end

  def put_current(_), do: :ok

  @doc "The process-local current request id, or nil."
  @spec current() :: request_id() | nil
  def current, do: Process.get(@pdkey)

  @doc """
  Append one event under `rid`. No-op for a nil id. Never raises.

  The buffer owns `seq`/`ts`: the stored event's `seq` is replaced with the
  request's next 1-based insertion-order counter and `ts` with the
  append-time monotonic clock, overwriting whatever `event.seq`/`event.ts`
  the caller's constructor set.
  """
  @spec append(request_id() | nil, Event.t()) :: :ok
  def append(nil, %Event{}), do: :ok

  def append(rid, %Event{} = event) when is_binary(rid) or is_integer(rid) do
    seq =
      :ets.update_counter(
        seq_table(),
        rid,
        {2, 1},
        {rid, 0, System.monotonic_time(:nanosecond)}
      )

    ts = System.monotonic_time(:nanosecond)
    :ets.insert(buf_table(), {{rid, seq}, ts, %{event | seq: 0, ts: 0}})

    :ok
  rescue
    _ -> :ok
  end

  def append(_rid, _event), do: :ok

  @doc "Append under the process-current id."
  @spec append_current(Event.t()) :: :ok
  def append_current(%Event{} = event), do: append(current(), event)

  @doc "Take (and clear) the seq-ordered event list for `rid`."
  @spec take(request_id() | nil) :: [Event.t()]
  def take(nil), do: []

  def take(rid) do
    spec = [{{{rid, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]
    rows = :ets.select(buf_table(), spec)
    :ets.match_delete(buf_table(), {{rid, :_}, :_, :_})
    :ets.delete(seq_table(), rid)

    rows
    |> Enum.sort_by(fn {seq, _ts, _event} -> seq end)
    |> Enum.map(fn {seq, ts, %Event{} = event} -> %Event{event | seq: seq, ts: ts} end)
  rescue
    _ -> []
  end

  @doc "Take the current id's list and clear the current id."
  @spec take_current() :: [Event.t()]
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
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    sweep()
    {:reply, :ok, state}
  end

  @doc false
  # Test-only synchronous sweep hook — the sweep is otherwise driven by a
  # 60s timer, too slow to exercise deterministically in the suite.
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  defp sweep do
    cutoff = System.monotonic_time(:nanosecond) - @ttl_ns
    :ets.select_delete(buf_table(), [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    :ets.select_delete(seq_table(), [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
