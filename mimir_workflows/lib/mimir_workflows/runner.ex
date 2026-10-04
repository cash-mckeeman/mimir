defmodule MimirWorkflows.Runner do
  @moduledoc """
  Executes a list of step specs in topological phase order.

  Steps whose dependencies are all satisfied by earlier phases share a
  phase and run concurrently via `Task.async_stream`; phases execute
  sequentially. A failure in any step halts the run and returns an error
  tuple carrying the step id.

  ## Step spec shape

      %{
        id: term(),
        module: module(),   # implements MimirWorkflows.Step
        params: map(),
        depends_on: [term()]
      }

  This shape is a **host-seam contract, not a runtime-validated one**: unlike
  `MimirWorkflows.Spec.parse/1`'s schema-validated IR, `run/2` does not check
  that a step map carries all four keys, that `module` implements
  `MimirWorkflows.Step`, or that `params`/`depends_on` have the right
  container type. `Dag.waves/1` validates *values* it can reason about
  (unknown `depends_on` ids, cycles) but assumes the *shape* is already
  correct. Callers that build specs from a schema-validated `%Spec{}` (e.g.
  via `MimirWorkflows.Compiler.compile/2`) get this for free; callers who
  hand-build specs are responsible for the shape themselves — a malformed
  entry raises (e.g. `KeyError`, `UndefinedFunctionError`) rather than
  returning a diagnostic.

  ## Return value

      {:ok, %{step_id => result_map}}
      | {:error, {:invalid, :cyclic | {:unknown_dependency, term()}}}
      | {:error, {:step_failed, step_id, reason}}
      | {:error, {:step_crashed, step_id, reason}}

  ## Telemetry

  | event | measurements | metadata |
  |---|---|---|
  | `[:mimir_workflows, :run, :start]` | `%{system_time}` | `%{run_ref}` ∪ `telemetry_meta` |
  | `[:mimir_workflows, :run, :stop]` | `%{duration}` (native) | `%{run_ref, status: :ok \\| :error}` ∪ `telemetry_meta` |
  | `[:mimir_workflows, :step, :start]` | `%{system_time}` | `%{run_ref, step_id, phase}` ∪ `telemetry_meta` |
  | `[:mimir_workflows, :step, :stop]` | `%{duration}` | `%{run_ref, step_id, phase}` ∪ `telemetry_meta` |
  | `[:mimir_workflows, :step, :exception]` | `%{duration}` | `%{run_ref, step_id, phase, reason}` ∪ `telemetry_meta` |

  A step whose task dies gets its `:exception` event from the runner
  process instead, and its `duration` is a bound, not a measurement:

    * killed on timeout: `reason: :timeout`, and `duration` is the configured
      deadline, a lower bound on the time since the task was spawned (just
      before `:start`); the timer fires late, never early.
    * any other exit, which reaches the runner only when the caller traps
      exits: `reason` is the exit reason, and `duration` the time since the
      step's phase began, an upper bound.

  Handlers for a step's own events run inside its task, so a slow `:stop`
  handler can push the task past its deadline; that step then gets `:stop`
  followed by a timeout `:exception`, and the run fails.

  The `:telemetry_meta` option is how hosts thread correlation ids
  (workflow ids, request ids) into every event without this library
  knowing what they mean. Emission is hand-rolled rather than
  `:telemetry.span/3` because a step's `{:error, _}` tuple is data, not a
  raise.
  """

  alias MimirWorkflows.Dag

  @typedoc "Opaque step identifier; compared by value only, never atomized."
  @type step_id :: term()

  @typedoc """
  One entry in the list passed to `run/2`. See "Step spec shape" above —
  this type documents the expected shape but `run/2` does not validate it
  at runtime.
  """
  @type step_spec :: %{
          id: step_id(),
          module: module(),
          params: map(),
          depends_on: [step_id()]
        }

  @type error ::
          {:invalid, :cyclic | {:unknown_dependency, step_id()}}
          | {:step_failed, step_id(), term()}
          | {:step_crashed, step_id(), term()}

  @default_timeout 120_000

  @doc """
  Runs the step specs and returns results keyed by step id.

  Options:

    * `:max_concurrency` — cap on in-phase parallelism; defaults to
      `System.schedulers_online()`, never more than the phase size.
    * `:timeout` — per-step timeout in milliseconds (default `120_000`);
      a timed-out step's task is killed and surfaces as
      `{:step_crashed, step_id, :timeout}`.
    * `:telemetry_meta` — map merged into every telemetry event's
      metadata (default `%{}`).
  """
  @spec run([step_spec()], keyword()) :: {:ok, %{step_id() => map()}} | {:error, error()}
  def run(steps, opts \\ [])

  def run([], _opts), do: {:ok, %{}}

  def run(steps, opts) do
    case Dag.waves(steps) do
      {:ok, phases} ->
        meta = base_meta(opts)
        started = emit_start([:run], %{}, meta)
        step_index = Map.new(steps, fn s -> {s.id, s} end)
        result = execute_phases(Enum.with_index(phases), step_index, %{}, opts, meta)
        status = if match?({:ok, _}, result), do: :ok, else: :error
        emit_stop([:run], started, %{}, Map.put(meta, :status, status))
        result

      {:error, reason} ->
        {:error, {:invalid, reason}}
    end
  end

  # ---- Phase execution ----

  defp execute_phases([], _index, acc, _opts, _meta), do: {:ok, acc}

  defp execute_phases([{phase, phase_idx} | rest], index, acc, opts, meta) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    phase_started = System.monotonic_time()

    results =
      phase
      |> Task.async_stream(
        fn step_id ->
          step = Map.fetch!(index, step_id)
          upstream = Map.take(acc, step.depends_on)
          step_meta = Map.merge(meta, %{step_id: step_id, phase: phase_idx})
          started = emit_start([:step], %{}, step_meta)

          outcome =
            try do
              step.module.run(step.params, upstream)
            catch
              kind, reason -> {:crashed, kind, reason}
            end

          case outcome do
            {:ok, _} = ok ->
              emit_stop([:step], started, %{}, step_meta)
              {step_id, ok}

            {:error, reason} = err ->
              emit_stop([:step], started, %{}, Map.put(step_meta, :reason, reason), :exception)
              {step_id, err}

            {:crashed, kind, reason} ->
              emit_stop(
                [:step],
                started,
                %{},
                Map.put(step_meta, :reason, {kind, reason}),
                :exception
              )

              {step_id, {:crashed, kind, reason}}
          end
        end,
        max_concurrency: max_concurrency(phase, opts),
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: false
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {step_id, {:ok, result}}}, {:ok, phase_acc} ->
          {:cont, {:ok, Map.put(phase_acc, step_id, result)}}

        {:ok, {step_id, {:error, reason}}}, _acc ->
          {:halt, {:error, {:step_failed, step_id, reason}}}

        {:ok, {step_id, {:crashed, kind, reason}}}, _acc ->
          {:halt, {:error, {:step_crashed, step_id, {kind, reason}}}}

        {:exit, {step_id, :timeout}}, _acc ->
          step_meta = Map.merge(meta, %{step_id: step_id, phase: phase_idx, reason: :timeout})
          emit_exit(System.convert_time_unit(timeout, :millisecond, :native), step_meta)
          {:halt, {:error, {:step_crashed, step_id, :timeout}}}

        {:exit, {step_id, reason}}, _acc ->
          step_meta = Map.merge(meta, %{step_id: step_id, phase: phase_idx, reason: reason})
          emit_exit(System.monotonic_time() - phase_started, step_meta)
          {:halt, {:error, {:step_crashed, step_id, reason}}}
      end)

    case results do
      {:ok, phase_results} ->
        execute_phases(rest, index, Map.merge(acc, phase_results), opts, meta)

      {:error, _} = error ->
        error
    end
  end

  defp max_concurrency(phase, opts) do
    opts
    |> Keyword.get(:max_concurrency, System.schedulers_online())
    |> min(length(phase))
    |> max(1)
  end

  # ---- Telemetry ----

  defp base_meta(opts) do
    opts
    |> Keyword.get(:telemetry_meta, %{})
    |> Map.put(:run_ref, make_ref())
  end

  defp emit_start(suffix, measurements, meta) do
    :telemetry.execute(
      [:mimir_workflows | suffix] ++ [:start],
      Map.put(measurements, :system_time, System.system_time()),
      meta
    )

    System.monotonic_time()
  end

  # A dead task never reached its own emit_stop, and its start time is not
  # visible here, so each caller passes a bound as duration: the deadline
  # (lower) or time since the phase began (upper). See "Telemetry" above.
  defp emit_exit(duration, meta) do
    :telemetry.execute([:mimir_workflows, :step, :exception], %{duration: duration}, meta)
  end

  defp emit_stop(suffix, started_at, measurements, meta, kind \\ :stop) do
    :telemetry.execute(
      [:mimir_workflows | suffix] ++ [kind],
      Map.put(measurements, :duration, System.monotonic_time() - started_at),
      meta
    )
  end
end
