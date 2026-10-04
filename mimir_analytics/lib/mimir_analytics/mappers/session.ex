defmodule MimirAnalytics.Mappers.Session do
  @moduledoc """
  Session JSONL into `runs`, `tool_calls` and optional `events_raw` rows.
  Accepts either a `meta`/`result` envelope or a flat run record containing
  `run_id`. Flat records are normalized once at ingress. Other shapes raise.

  Session identity comes from `result["session_id"]`, with `meta["run_id"]`
  as a legacy fallback. Caller-local correlation keys do not override it.
  Flat `run_id` values map onto the same identity field.

  `terminal` and `stop_reason` retain the producer's vocabulary; a non-string
  stop reason is stored with `inspect/1`. `outcome` is the producer's derived
  status, and `error_class` is its classification. Raw `error` terms are not
  read. Missing optional values remain null, while missing usage and cost
  values become zero. Cost comes from the source; per-call model rows are
  never synthesized.

  Custom and server tool uses retain their order. Flat `tool_calls` roll-ups
  expand into `count` occurrences with kind `"rollup"`, without invocation
  ids or arguments. Missing counts mean one; non-string names and negative
  or non-integer counts raise.

  Optional envelope events retain `domain` and `seq`; missing sequences use
  array order. No per-event wall-clock is invented. Missing events yield no
  event rows. The mapper writes no per-turn rows.

  A file's rows and content-keyed ingest ledger entry commit together.
  Already-ingested contents return `:already_ingested`. Empty files and
  read failures return errors; malformed JSON or records raise.
  """

  @behaviour MimirAnalytics.Mapper

  alias MimirAnalytics.{Mapper, Store}
  alias MimirAnalytics.Row.{EventRaw, Run, ToolCall}

  @impl true
  @spec ingest(Store.t(), Path.t()) ::
          {:ok, Mapper.summary()} | :already_ingested | {:error, term()}
  def ingest(store, path) do
    # A spool file can be moved aside by a concurrent ingester between the
    # directory listing and this read; that is an `{:error, _}` for this
    # file, not an exception that aborts the caller's whole run. A published
    # file always holds at least one line, so an empty one is a writer that
    # opened the final name before writing to it: an error, never a
    # successful ingest of 0 rows, and the file stays for the next run.
    case File.read(path) do
      {:ok, ""} -> {:error, :empty_file}
      {:ok, bytes} -> ingest_bytes(store, Path.basename(path), bytes)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp ingest_bytes(store, file, bytes) do
    digest = Store.digest(bytes)

    if Store.ingested?(store, digest) do
      :already_ingested
    else
      ingest_new(store, file, digest, bytes)
    end
  end

  defp ingest_new(store, file, digest, bytes) do
    entries =
      bytes
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&normalize/1)

    run_rows = Enum.map(entries, &run_row(&1, file))
    tool_rows = Enum.flat_map(entries, &tool_rows(&1, file))
    event_rows = Enum.flat_map(entries, &event_rows(&1, file))

    Store.transaction(store, &insert_all(&1, {digest, file}, run_rows, tool_rows, event_rows))
  end

  @spec insert_all(
          Store.t(),
          {String.t(), String.t()},
          [Run.t()],
          [ToolCall.t()],
          [EventRaw.t()]
        ) :: {:ok, Mapper.summary()} | {:error, term()}
  defp insert_all(store, {digest, file}, run_rows, tool_rows, event_rows) do
    with {:ok, nr} <- Store.insert(store, "runs", run_rows),
         {:ok, nt} <- Store.insert(store, "tool_calls", tool_rows),
         {:ok, ne} <- Store.insert(store, "events_raw", event_rows),
         :ok <- Store.record_ingest(store, digest, file, "session", nr + nt + ne) do
      {:ok, %{rows: %{"runs" => nr, "tool_calls" => nt, "events_raw" => ne}}}
    end
  end

  # Already the `meta`/`result` shape (the older Capture session line) —
  # nothing to do. This is the ONE place a decoded line's shape is decided;
  # every function past this point reads `meta`/`result` and never asks
  # which producer wrote the line.
  @spec normalize(Mapper.source_map()) :: Mapper.source_map()
  defp normalize(%{"meta" => _, "result" => _} = entry), do: entry

  # A RunRecord line: flat, no envelope. Rebuild the meta/result pair
  # `Row.Run`/`Row.ToolCall`/`Row.EventRaw` already know how to read. Guarded
  # on `run_id` (RunRecord's one `@enforce_keys` field with no equivalent in
  # the other clause) rather than a bare catch-all, so a line shaped like
  # neither contract raises a `FunctionClauseError` naming the actual
  # mismatch here, instead of silently becoming a run row that fails later
  # with an opaque NOT NULL constraint violation at insert time.
  defp normalize(record) when is_map_key(record, "run_id") do
    %{
      "meta" => %{
        "workflow_id" => record["workflow_id"],
        "step_id" => record["step_id"],
        "parent_step_id" => record["parent_step_id"],
        "tenant_id" => record["tenant_id"],
        "runtime" => record["runtime"],
        "agent_name" => record["agent"],
        "started_at" => record["started_at"],
        "finished_at" => record["finished_at"],
        "cost_microdollars" => record["cost_microdollars"]
      },
      "result" => %{
        "session_id" => record["run_id"],
        "outcome" => record["outcome"],
        "terminal" => record["terminal"],
        "stop_reason" => record["stop_reason"],
        "error_class" => record["error_class"],
        "turns" => record["turns"],
        "usage" => %{
          "input_tokens" => record["input_tokens"],
          "output_tokens" => record["output_tokens"]
        },
        "tool_calls" => record["tool_calls"] || []
      }
    }
  end

  @spec run_row(Mapper.source_map(), String.t()) :: Run.t()
  defp run_row(entry, file), do: Run.new(Map.put(entry, "source_file", file))

  @spec tool_rows(Mapper.source_map(), String.t()) :: [ToolCall.t()]
  defp tool_rows(%{"meta" => m, "result" => r}, file) do
    run_id = Run.run_id(m, r)
    custom = Enum.map(r["custom_tool_uses"] || [], &{&1, "custom"})
    server = Enum.map(r["server_tool_uses"] || [], &{&1, "server"})
    rollup = Enum.map(roll_up_occurrences(r["tool_calls"]), &{&1, "rollup"})

    for {{tu, kind}, i} <- Enum.with_index(custom ++ server ++ rollup, 1) do
      ToolCall.new(%{
        run_id: run_id,
        turn: nil,
        seq: i,
        tool_use: tu,
        kind: kind,
        source_file: file
      })
    end
  end

  # One occurrence per count, name only — a roll-up carries no tool-use id
  # or input to hand to `ToolCall.new/1`. A roll-up without a string `name`,
  # or whose `count` is not a non-negative integer, raises: like a line of
  # neither shape in `normalize/1`, it is never dropped silently.
  @spec roll_up_occurrences([map()] | nil) :: [map()]
  defp roll_up_occurrences(roll_ups), do: Enum.flat_map(roll_ups || [], &occurrences/1)

  defp occurrences(%{"name" => name} = roll_up) when is_binary(name) do
    case roll_up["count"] || 1 do
      n when is_integer(n) and n >= 0 -> List.duplicate(%{"name" => name}, n)
      _ -> malformed_roll_up!(roll_up)
    end
  end

  defp occurrences(roll_up), do: malformed_roll_up!(roll_up)

  defp malformed_roll_up!(roll_up) do
    raise ArgumentError, "malformed tool_calls roll-up: #{inspect(roll_up)}"
  end

  @spec event_rows(Mapper.source_map(), String.t()) :: [EventRaw.t()]
  defp event_rows(%{"meta" => m, "result" => r}, file) do
    run_id = Run.run_id(m, r)

    for {ev, i} <- Enum.with_index(r["events"] || [], 1) do
      EventRaw.new(%{
        scope_id: run_id,
        seq: ev["seq"] || i,
        ts: nil,
        domain: ev["domain"],
        type: ev["type"],
        payload: ev,
        source: "session",
        source_file: file
      })
    end
  end
end
