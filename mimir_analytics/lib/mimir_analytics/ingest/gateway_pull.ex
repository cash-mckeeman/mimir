defmodule MimirAnalytics.Ingest.GatewayPull do
  @moduledoc """
  Buffers legacy v1 request logs by `updated_since`. Explicit `api_version: 2`
  pulls accounting with a caller-owned source identity and Store; only a database
  commit acknowledges its opaque cursor. V2 errors exclude transport details.

  Stale or uncertain acknowledgements reload and refetch, with at most three
  recovery retries per pull. V2 buffers remain available for Mapper replay.
  """

  alias MimirAnalytics.Accounting.{Error, Page, Source}
  alias MimirAnalytics.{AccountingStore, Store}
  alias MimirAnalytics.Ingest.GatewayAccountingBuffer
  alias MimirAnalytics.Ingest.GatewayPull.Result

  @endpoint "/admin/api/v1/request-log"
  @page_limit 500

  # The mimir library's CloudEvents type taxonomy owns this string; it is
  # pinned here because the dependency-direction invariant forbids naming that
  # module. Provenance for the fixture that proves the two agree: the fixtures
  # README.
  @routing_decision_type "ai.bizinsights.mimir.routing.decision"

  @doc "V2 requires source_id/store and owns its cursor. The optional db adapter follows Store.DB."
  @spec pull(keyword()) ::
          {:ok, %{files: [Path.t()], last_cursor: String.t() | nil} | Result.t()}
          | {:error, Error.t()}
  def pull(opts) do
    case Keyword.get(opts, :api_version, 1) do
      1 -> pull_v1(opts)
      2 -> pull_accounting(opts)
      _ -> Error.result(:unsupported_version, :api_version)
    end
  end

  defp pull_accounting(opts) do
    with :ok <- accounting_options(opts),
         {:ok, source} <- Source.new(%{source_id: opts[:source_id], api_version: 2}) do
      accounting_loop(opts, source, [], 3)
    end
  end

  defp accounting_options(opts) do
    cond do
      Enum.any?([:updated_since, :cursor, :from_cursor], &Keyword.has_key?(opts, &1)) ->
        Error.result(:invalid_page, :cursor)

      not match?(%Store{}, opts[:store]) ->
        Error.result(:storage_error)

      not Enum.all?([:base_url, :token, :dir], &is_binary(opts[&1])) ->
        Error.result(:invalid_page)

      true ->
        :ok
    end
  end

  defp accounting_loop(opts, source, files, retries) do
    db_opts = Keyword.take(opts, [:db])

    with {:ok, checkpoint} <- AccountingStore.checkpoint(opts[:store], source, db_opts),
         {:ok, body} <- accounting_request(opts, checkpoint.cursor),
         {:ok, page} <- Page.new(body, source, checkpoint.cursor),
         {:ok, receipt, path} <- GatewayAccountingBuffer.publish(page, opts[:dir]) do
      acknowledge(opts, source, files, retries, checkpoint, receipt, path)
    end
  end

  defp acknowledge(opts, source, files, retries, checkpoint, page, path) do
    case AccountingStore.ingest_page(
           opts[:store],
           page,
           {:advance, checkpoint},
           Keyword.take(opts, [:db])
         ) do
      {:ok, _} ->
        continue_accounting(opts, source, [path | files], retries, page)

      {:error, %Error{code: code}}
      when code in [:checkpoint_conflict, :commit_uncertain] and retries > 0 ->
        accounting_loop(opts, source, files, retries - 1)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp continue_accounting(_opts, _source, files, _retries, %Page{events: [], next_cursor: cursor}),
       do: Result.new(%{files: Enum.reverse(files), last_cursor: cursor})

  defp continue_accounting(opts, source, files, retries, _page),
    do: accounting_loop(opts, source, files, retries)

  defp accounting_request(opts, cursor) do
    params =
      if is_nil(cursor), do: [limit: @page_limit], else: [cursor: cursor, limit: @page_limit]

    request =
      Keyword.merge(Keyword.get(opts, :req_options, []),
        base_url: opts[:base_url],
        url: "/admin/api/v2/accounting",
        auth: {:bearer, opts[:token]},
        params: params,
        retry: false
      )

    case Req.get(request) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:ok, error} = Error.new(%{code: :http_error, http_status: status})
        {:error, error}

      {:error, _} ->
        Error.result(:transport_error)
    end
  rescue
    _ -> Error.result(:transport_error)
  end

  defp pull_v1(opts) do
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
