defmodule Mimir.Health do
  @moduledoc """
  Failure-streak table for router lanes.

  **This is NOT a circuit breaker.** There is no half-open state and no
  automatic probe logic. Any single success resets the streak to zero. The
  `:degraded` state is purely informational: the Oracle uses it to exclude
  the lane from routing candidates during a snapshot window. Recovery happens
  the moment the next successful completion arrives.

  State is stored in an ETS table owned by this GenServer. All reads and
  writes go directly to ETS (no GenServer call overhead) — the GenServer
  exists only for lifecycle (create table on start, supervise ownership).

  ## Lane naming

  A "lane" is the provider prefix of a resolved model string — e.g. the lane
  for `"anthropic:claude-sonnet-4-6"` is `"anthropic"`. The telemetry handler
  derives this by splitting on the first `":"`. This matches the convention
  used in the router catalog (`lane: "anthropic"`) and the Oracle's
  `snap.health` lookup key.

  ## Threshold

  `:degraded` when `streak >= Application.get_env(:mimir, :health_threshold, 3)`.
  The threshold is read at call time so it can be overridden in tests without
  restarting the GenServer.

  ## Completion event

  `attach/0` binds the handler to `Application.get_env(:mimir, :completion_event,
  [:mimir, :completion])`. An embedder that emits its own app-namespaced
  completion event can point Health at it by setting `:mimir, :completion_event`
  in config.
  """

  use GenServer

  @table :mimir_router_health
  @handler_id "mimir-router-health"

  # ── public API ────────────────────────────────────────────────────────────

  @doc "Attach the telemetry handler for the configured completion event (`:mimir, :completion_event`)."
  @spec attach() :: :ok | {:error, term()}
  def attach do
    :telemetry.attach(@handler_id, completion_event(), &__MODULE__.handle_event/4, nil)
  end

  defp completion_event,
    do: Application.get_env(:mimir, :completion_event, [:mimir, :completion])

  @doc false
  def handle_event(_event, _measurements, %{model: model, outcome: outcome}, _config) do
    lane = lane_from_model(model)

    case outcome do
      :ok -> record_success(lane)
      _ -> record_failure(lane)
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc "Reset the failure streak for `lane` to 0."
  @spec record_success(String.t()) :: :ok
  def record_success(lane) do
    :ets.insert(@table, {lane, 0})
    :ok
  end

  @doc "Increment the failure streak for `lane` by 1."
  @spec record_failure(String.t()) :: :ok
  def record_failure(lane) do
    :ets.update_counter(@table, lane, {2, 1}, {lane, 0})
    :ok
  end

  @doc "Returns `:ok` or `:degraded` for `lane`. Unknown lanes are `:ok`."
  @spec state(String.t()) :: :ok | :degraded
  def state(lane) do
    threshold = Application.get_env(:mimir, :health_threshold, 3)

    case :ets.lookup(@table, lane) do
      [{^lane, streak}] when streak >= threshold -> :degraded
      _ -> :ok
    end
  end

  @doc """
  Returns a `lane → state` map for every lane that has been recorded.
  Used by `Snapshot.assemble/1` to populate `health`.
  """
  @spec all() :: %{String.t() => :ok | :degraded}
  def all do
    threshold = Application.get_env(:mimir, :health_threshold, 3)

    :ets.tab2list(@table)
    |> Map.new(fn {lane, streak} ->
      {lane, if(streak >= threshold, do: :degraded, else: :ok)}
    end)
  end

  @doc "Delete all rows from the health table. Intended for test isolation only."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer lifecycle ───────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, nil}
  end

  # ── private helpers ───────────────────────────────────────────────────────

  # Derive the provider lane from a resolved model string. "anthropic:claude-sonnet-4-6"
  # → "anthropic". Models without a ":" are returned as-is.
  defp lane_from_model(model) when is_binary(model) do
    model |> String.split(":", parts: 2) |> hd()
  end

  defp lane_from_model(model), do: to_string(model)
end
