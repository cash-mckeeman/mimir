defmodule MimirAnalytics.Mappers.EvalReport do
  @moduledoc """
  `eval_runs/*.json` report → `eval_outcomes` rows (the original eval-ingest
  long format, widened with agent/suite/runtime/run_id). Idempotent by
  file contents.

  Eval reports are left in place, and `eval_outcomes` has no row key, so a
  report rewritten after it was ingested would add its rows a second time.
  New contents under a report name already ingested are therefore rejected
  with `{:error, {:changed_after_ingest, name}}`, and an empty report with
  `{:error, :empty_file}`. Reports have other readers, so a rejected report
  stays where it is: the rejection is recorded in `ingest_rejections` by
  content digest, and the same contents answer `:already_rejected` from
  then on. New contents are judged afresh.
  """

  @behaviour MimirAnalytics.Mapper

  alias MimirAnalytics.{Mapper, Store}
  alias MimirAnalytics.Row.EvalOutcome
  alias MimirAnalytics.Row.EvalOutcome.Case

  @impl true
  @spec ingest(Store.t(), Path.t()) ::
          {:ok, Mapper.summary()} | :already_ingested | :already_rejected | {:error, term()}
  def ingest(store, path) do
    file = Path.basename(path)
    bytes = File.read!(path)
    digest = Store.digest(bytes)

    cond do
      Store.ingested?(store, digest) ->
        :already_ingested

      Store.rejected?(store, digest) ->
        :already_rejected

      bytes == "" ->
        reject(store, digest, file, :empty_file)

      Store.ingested_name?(store, "eval", file) ->
        reject(store, digest, file, {:changed_after_ingest, file})

      true ->
        rows = bytes |> Jason.decode!() |> eval_rows(file)
        Store.transaction(store, &insert_all(&1, {digest, file}, rows))
    end
  end

  defp reject(store, digest, file, reason) do
    with :ok <- Store.record_rejection(store, digest, file, "eval", inspect(reason)) do
      {:error, reason}
    end
  end

  @spec insert_all(Store.t(), {String.t(), String.t()}, [EvalOutcome.t()]) ::
          {:ok, Mapper.summary()} | {:error, term()}
  defp insert_all(store, {digest, file}, rows) do
    with {:ok, n} <- Store.insert(store, "eval_outcomes", rows),
         :ok <- Store.record_ingest(store, digest, file, "eval", n) do
      {:ok, %{rows: %{"eval_outcomes" => n}}}
    end
  end

  @spec eval_rows(Mapper.source_map(), String.t()) :: [EvalOutcome.t()]
  defp eval_rows(data, file) do
    judges = Map.new(data["judge_results"] || [], fn j -> {j["case_id"], j} end)
    args = data["args"] || %{}

    for c <- data["results"] || [] do
      case_row = Case.new(c, judges[c["case_id"]] || %{})

      EvalOutcome.new(%{
        case: case_row,
        agent: data["agent"],
        suite: data["suite"],
        runtime: data["runtime"],
        mode: args["mode"] || "mechanical",
        threshold: args["threshold"] || 0.0,
        pass_rate: data["pass_rate"] || 0.0,
        ts: file_ts(file),
        source_file: file
      })
    end
  end

  # `1779810442.json` (unix ts) or any name → ISO timestamp or nil
  defp file_ts(file) do
    case file |> Path.rootname() |> Integer.parse() do
      {unix, ""} -> unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
      _ -> nil
    end
  end
end
