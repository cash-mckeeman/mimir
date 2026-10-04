defmodule MimirAnalytics.Ingest.GatewayPull do
  @moduledoc """
  Pulls the gateway's read-only Observability API (`updated_since` cursor)
  and buffers each page as run-record JSONL — the same line shapes the
  gateway-export mapper ingests, so the buffer file is the contract wherever
  the bytes came from. Plain HTTP + maps only (dependency-direction
  invariant).

  Routing decisions are not a top-level API field: they ride inside each row's
  `turn_events` (as `ai.bizinsights.mimir.routing.decision` CloudEvents, or as
  bare `routing_decision` entries on rows predating CloudEvents) and are
  lifted out here into their own `routing_decision` buffer lines.

  The endpoint below is the contract this module is written against. The
  gateway now serves it behind its own read-only credential, so this module is
  live-runnable; the cursor it echoes is composite (`<rfc3339>|<uuid>`) and is
  passed back verbatim, never parsed here.

  Buffer filenames are collision-free by construction (`page_filename/3`) —
  the buffer file is the ingest contract, and a name collision would drop a
  page silently.
  """

  @endpoint "/admin/api/v1/request-log"
  @page_limit 500

  # The mimir library's CloudEvents type taxonomy owns this string; it is
  # pinned here because the dependency-direction invariant forbids naming that
  # module. Provenance for the fixture that proves the two agree: the fixtures
  # README.
  @routing_decision_type "ai.bizinsights.mimir.routing.decision"

  @spec pull(keyword()) :: {:ok, %{files: [Path.t()], last_cursor: String.t() | nil}}
  def pull(opts) do
    base = Keyword.fetch!(opts, :base_url)
    token = Keyword.fetch!(opts, :token)
    dir = Keyword.fetch!(opts, :dir)
    cursor = Keyword.fetch!(opts, :updated_since)
    req_options = Keyword.get(opts, :req_options, [])

    File.mkdir_p!(dir)
    do_pull(base, token, dir, cursor, req_options, [], 0)
  end

  defp do_pull(base, token, dir, cursor, req_options, files, page) do
    %{status: 200, body: body} =
      Req.get!(
        [
          base_url: base,
          url: @endpoint,
          auth: {:bearer, token},
          params: [updated_since: cursor, limit: @page_limit]
        ] ++ req_options
      )

    case body do
      %{"rows" => []} ->
        {:ok, %{files: Enum.reverse(files), last_cursor: cursor}}

      %{"rows" => rows, "next_updated_since" => next} ->
        next = next || last_inserted_at(rows) || cursor
        path = Path.join(dir, page_filename(page, cursor, next))
        lines = Enum.flat_map(rows, &[request_log_line(&1) | decision_lines(&1)])
        File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
        do_pull(base, token, dir, next, req_options, [path | files], page + 1)
    end
  end

  # Collision-free by construction, which the previous name was not: it
  # squeezed the cursor down to its digits, so two composite cursors sharing a
  # timestamp could sanitize to one filename and the second page would
  # silently overwrite the first — records lost before they ever reached the
  # store, with a successful write and nothing to notice it.
  #
  # The page ordinal separates pages within a pull; the digest separates
  # distinct cursor ranges across pulls. The readable timestamp is a human
  # convenience only and carries no uniqueness burden.
  defp page_filename(page, from, to) do
    ordinal = page |> Integer.to_string() |> String.pad_leading(4, "0")

    digest =
      :crypto.hash(:sha256, "#{from}\n#{to}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "gateway_pull-#{ordinal}-#{readable(from)}-#{digest}.jsonl"
  end

  defp request_log_line(row), do: Map.put(row, "kind", "request_log")

  # A routing decision reaches analytics inside the request's `turn_events`:
  # enveloped as a `routing.decision` CloudEvent whose
  # `data` is the decision-record audit map, or — for rows the gateway never
  # backfilled — as the bare `%{"type" => "routing_decision", "decision" =>
  # ...}` entry. Both flatten to the same buffer line, which is what
  # `MimirAnalytics.Row.RoutingDecision.new/1` reads.
  defp decision_lines(row), do: row |> events_list() |> Enum.flat_map(&decision_line(&1, row))

  defp decision_line(%{"type" => @routing_decision_type, "time" => time, "data" => d}, _row)
       when is_map(d),
       do: [decision_line_from(d, time)]

  defp decision_line(%{"type" => @routing_decision_type, "data" => d}, row) when is_map(d),
    do: [decision_line_from(d, row["inserted_at"])]

  defp decision_line(%{"type" => "routing_decision", "decision" => d}, row) when is_map(d),
    do: [decision_line_from(d, row["inserted_at"])]

  defp decision_line(_entry, _row), do: []

  defp decision_line_from(decision, ts),
    do: decision |> Map.put("kind", "routing_decision") |> Map.put("ts", ts)

  # `request_log.turn_events` is the map the gateway's request-log writer
  # persists (`%{events: [...]}`); the bare-list form is tolerated for buffer
  # files written by hand.
  defp events_list(%{"turn_events" => %{"events" => events}}) when is_list(events), do: events
  defp events_list(%{"turn_events" => events}) when is_list(events), do: events
  defp events_list(_), do: []

  defp last_inserted_at(rows), do: rows |> List.last() |> Map.get("inserted_at")

  # Legibility only — the digest above carries uniqueness. A composite cursor
  # is `<rfc3339>|<uuid>`; only the timestamp half is worth reading in a
  # directory listing.
  defp readable(nil), do: "open"
  defp readable(""), do: "open"

  defp readable(cursor) do
    cursor
    |> String.split("|", parts: 2)
    |> hd()
    |> String.replace(~r/[^0-9T]/, "")
  end
end
