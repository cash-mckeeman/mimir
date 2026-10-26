defmodule MimirAnalytics.Mappers.GatewayExport do
  @moduledoc """
  Gateway JSONL buffers contain legacy request/routing rows or one
  `accounting_page` wrapper. Accounting pages commit atomically through
  `MimirAnalytics.AccountingStore` and retain `:already_ingested` replay status.

  Legacy "request_log" and "routing_decision" rows are written by
  `MimirAnalytics.Ingest.GatewayPull` from the gateway Observability API.

  `request_log` lines carry `turn_events` as `%{"events" => [...]}` — the map
  the gateway's request-log writer persists, not a bare array. Each entry is
  either a CloudEvents v1.0 envelope or a pre-envelope
  event/`routing_decision` map; both map one-for-one into `events_raw`, with
  the envelope's `id`/`source`/`type`/`time` in the `ce_*` and `ts` columns
  and NULL there for history.
  """

  @behaviour MimirAnalytics.Mapper

  alias MimirAnalytics.Accounting.Page
  alias MimirAnalytics.{AccountingStore, Mapper, Store}
  alias MimirAnalytics.Row.{EventRaw, ModelCall, RoutingDecision}

  @impl true
  @spec ingest(Store.t(), Path.t()) ::
          {:ok, Mapper.summary()} | :already_ingested | {:error, term()}
  def ingest(store, path) do
    file = Path.basename(path)
    bytes = File.read!(path)
    digest = Store.digest(bytes)

    if Regex.match?(~r/\Agateway_accounting-[0-9a-f]{64}\.jsonl\z/, file) or
         accounting_buffer?(bytes) do
      with {:ok, page} <- Page.from_buffer(bytes, file) do
        AccountingStore.ingest_page(store, page, :replay)
      end
    else
      if Store.ingested?(store, digest) do
        :already_ingested
      else
        ingest_new(store, {digest, file}, bytes)
      end
    end
  end

  defp accounting_buffer?(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      case Jason.decode(line) do
        {:ok, wire} when is_map(wire) -> accounting_wire?(wire)
        _ -> String.contains?(line, "\"accounting_page\"")
      end
    end)
  end

  defp accounting_wire?(wire) do
    wire["kind"] == "accounting_page" or
      Enum.any?(["api_version", "schema_version", "buffer_version"], &Map.has_key?(wire, &1))
  end

  defp ingest_new(store, {_digest, file} = key, bytes) do
    lines =
      bytes
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)

    calls = for %{"kind" => "request_log"} = l <- lines, do: call_row(l, file)
    decisions = for %{"kind" => "routing_decision"} = l <- lines, do: decision_row(l, file)
    events = Enum.flat_map(lines, &event_rows(&1, file))

    Store.transaction(store, &insert_all(&1, key, calls, decisions, events))
  end

  @spec insert_all(
          Store.t(),
          {String.t(), String.t()},
          [ModelCall.t()],
          [RoutingDecision.t()],
          [EventRaw.t()]
        ) :: {:ok, Mapper.summary()} | {:error, term()}
  defp insert_all(store, {digest, file}, calls, decisions, events) do
    with {:ok, nc} <- Store.insert(store, "model_calls", calls),
         {:ok, nd} <- Store.insert(store, "routing_decisions", decisions),
         {:ok, ne} <- Store.insert(store, "events_raw", events),
         :ok <- Store.record_ingest(store, digest, file, "gateway", nc + nd + ne) do
      {:ok, %{rows: %{"model_calls" => nc, "routing_decisions" => nd, "events_raw" => ne}}}
    end
  end

  @doc "Resolve model_calls.run_id by (workflow_id, step_id) against runs."
  @spec resolve_run_ids(Store.t()) :: :ok
  def resolve_run_ids(store) do
    {:ok, _} =
      Store.query(store, """
      UPDATE model_calls
      SET run_id = r.run_id
      FROM runs r
      WHERE model_calls.run_id IS NULL
        AND model_calls.workflow_id = r.workflow_id
        AND model_calls.step_id = r.step_id
      """)

    :ok
  end

  @spec call_row(Mapper.source_map(), String.t()) :: ModelCall.t()
  defp call_row(l, file), do: ModelCall.new(Map.put(l, "source_file", file))

  @spec decision_row(Mapper.source_map(), String.t()) :: RoutingDecision.t()
  defp decision_row(l, file), do: RoutingDecision.new(Map.put(l, "source_file", file))

  # The CloudEvents v1.0 JSON event-format attribute names are an open standard,
  # not a mimir-private shape, so they are read as plain map keys here — the
  # dependency-direction invariant (MimirAnalytics.DepDirectionTest) forbids
  # naming the mimir envelope module. Entry shapes are told apart by STRUCTURE,
  # never by a type-string list: `"specversion"` ⇒ enveloped; anything else is
  # pre-envelope history (a bare event wire map, or a bare `routing_decision`
  # entry), which the gateway never backfilled.
  @spec event_rows(Mapper.source_map(), String.t()) :: [EventRaw.t()]
  defp event_rows(%{"kind" => "request_log"} = l, file) do
    for {entry, i} <- Enum.with_index(turn_events(l), 1), do: event_row(entry, i, l, file)
  end

  defp event_rows(_, _file), do: []

  # `request_log.turn_events` is a MAP: the gateway's request-log writer wraps
  # the event list as `%{events: [...]}` before persisting. The bare-list form
  # is tolerated for buffer files written by hand.
  defp turn_events(%{"turn_events" => %{"events" => events}}) when is_list(events), do: events
  defp turn_events(%{"turn_events" => events}) when is_list(events), do: events
  defp turn_events(_), do: []

  # Enveloped: envelope attributes become columns, the body supplies the
  # lifecycle fields, and `payload` keeps the WHOLE envelope — events_raw is the
  # backstop that never discards what it was given. A routing-decision or
  # ledger-completion body carries no `domain`/`type`, and none is invented:
  # `ce_type` is what names those families.
  defp event_row(%{"specversion" => _} = ce, i, l, file) do
    data = as_map(ce["data"])

    EventRaw.new(%{
      scope_id: scope_id(data, l),
      seq: data["seq"] || i,
      ts: ce["time"],
      domain: data["domain"],
      type: data["type"],
      ce_id: ce["id"],
      ce_source: ce["source"],
      ce_type: ce["type"],
      payload: ce,
      source: "gateway",
      source_file: file
    })
  end

  # Pre-envelope: no producer ever emitted a wall-clock for these, so `ts` stays
  # NULL rather than borrowing the enclosing row's `inserted_at` — a per-request
  # value that would read as per-event data.
  defp event_row(entry, i, l, file) do
    EventRaw.new(%{
      scope_id: scope_id(entry, l),
      seq: entry["seq"] || i,
      ts: nil,
      domain: entry["domain"],
      type: entry["type"],
      payload: entry,
      source: "gateway",
      source_file: file
    })
  end

  defp scope_id(body, l), do: as_map(body["ids"])["request_id"] || l["request_id"]

  defp as_map(m) when is_map(m), do: m
  defp as_map(_), do: %{}
end
