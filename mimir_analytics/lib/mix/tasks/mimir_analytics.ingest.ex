defmodule Mix.Tasks.MimirAnalytics.Ingest do
  @shortdoc "Ingest session/gateway/eval buffer files into the run-record store"
  @moduledoc """
  Ingests every non-ledgered buffer file, resolves model-call run ids, and
  (re)applies the consumer views. See the README.

  Only `--sessions` is a spool: each session file that ingests is moved
  into `<dir>/.ingested/`. `--gateway` and `--evals` files are left where
  they are — other tools read those directories — and re-runs skip them
  through the ingest ledger.

  The spool's write protocol: a producer writes each file once, under a
  dot-prefixed temporary name in the same directory, and renames it to its
  final `*.jsonl` name when it is complete. Only those published names are
  read; a temporary file is neither ingested nor moved.

  `--db` accepts a local path (dev/test) or `motherduck:<db_name>`
  (deployment; token from MOTHERDUCK_TOKEN).
  """
  use Mix.Task

  alias MimirAnalytics.{Mappers, Store, Views}

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [db: :string, sessions: :string, gateway: :string, evals: :string]
      )

    store = opts |> Keyword.fetch!(:db) |> open!()

    # Closed whether or not a file raises, so a later run on the same file
    # never overlaps this instance's close.
    counts =
      try do
        ingest_all(store, opts)
      after
        :ok = Store.close(store)
      end

    Mix.shell().info("ingested: #{inspect(counts)}")
  end

  defp ingest_all(store, opts) do
    counts = %{
      sessions: ingest_dir(store, opts[:sessions], "*.jsonl", &Mappers.Session.ingest/2, spool()),
      gateway:
        ingest_dir(store, opts[:gateway], "*.jsonl", &Mappers.GatewayExport.ingest/2, in_place()),
      evals: ingest_dir(store, opts[:evals], "*.json", &Mappers.EvalReport.ingest/2, in_place())
    }

    :ok = Mappers.GatewayExport.resolve_run_ids(store)
    :ok = Views.apply(store.conn)
    counts
  end

  defp open!(db) do
    case db |> parse_target() |> Store.open() do
      {:ok, store} ->
        store

      {:error, :name_keyed_ledger} ->
        Mix.raise(
          "mimir_analytics.ingest: #{db} keeps an ingest ledger keyed by file name, " <>
            "which cannot tell a grown file from a read one. Rebuild it: delete the " <>
            "database and re-ingest the source directories (README, \"Upgrading a database\")."
        )
    end
  end

  defp parse_target("motherduck:" <> db_name), do: {:motherduck, db_name}
  defp parse_target(path), do: path

  # What happens to a file after its mapper answers. Only the sessions
  # directory is a spool the ingester owns, so only its files are moved;
  # other tools read the gateway and eval directories.
  defp spool,
    do: %{ingested: &archive_ingested/1, duplicate: &archive_duplicate/1, failed: &set_aside/2}

  defp in_place,
    do: %{ingested: &leave_in_place/1, duplicate: &leave_in_place/1, failed: &report/2}

  defp ingest_dir(_store, nil, _glob, _fun, _handling), do: 0

  defp ingest_dir(store, dir, glob, fun, handling) do
    # `Path.wildcard/1` matches direct children of `dir` only — it never
    # descends into a subdirectory, dotted or not — so `.ingested/` (created
    # below) is never re-listed here. It also skips dot-prefixed names, which
    # is what keeps a producer's unpublished temporary file out of the run.
    dir
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.count(fn path ->
      case fun.(store, path) do
        {:ok, _} ->
          handling.ingested.(path)
          true

        :already_ingested ->
          handling.duplicate.(path)
          false

        :already_rejected ->
          false

        {:error, reason} ->
          handling.failed.(path, reason)
          false
      end
    end)
  end

  defp leave_in_place(_path), do: :ok

  # An empty spool file can never be ingested. Left in the spool, it would be
  # reported again on every run, so it is reported once and moved into
  # `.quarantined/` beside the archive, which no run reads, with a
  # `<name>.reason` sidecar saying why. Moving it back re-queues it. Other
  # failures may clear on a later run and stay in place.
  defp set_aside(path, :empty_file = reason), do: quarantine(path, reason)
  defp set_aside(path, reason), do: report(path, reason)

  defp report(path, reason) do
    Mix.shell().error("mimir_analytics.ingest: could not ingest #{path}: #{inspect(reason)}")
  end

  defp quarantine(path, reason) do
    quarantine = Path.join(Path.dirname(path), ".quarantined")

    with :ok <- File.mkdir_p(quarantine),
         {:ok, dest} <- link_into(quarantine, path, 0),
         :ok <- File.write(dest <> ".reason", inspect(reason) <> "\n"),
         :ok <- File.rm(path) do
      Mix.shell().error(
        "mimir_analytics.ingest: quarantined #{path} as #{dest}: #{inspect(reason)}"
      )
    else
      {:error, move_reason} ->
        Mix.shell().error(
          "mimir_analytics.ingest: could not ingest #{path}: #{inspect(reason)}, " <>
            "and could not quarantine it: #{inspect(move_reason)}"
        )
    end
  end

  # A spool file whose exact bytes the ledger already holds, such as a
  # byte-identical duplicate or a file whose earlier move failed. The digest
  # match proves those bytes were committed, so it leaves the spool the same
  # way an ingested file does, and the skip is reported.
  defp archive_duplicate(path) do
    Mix.shell().info(
      "mimir_analytics.ingest: #{path} has contents already ingested; moving it aside"
    )

    archive_ingested(path)
  end

  # The capture directory is a spool, not an archive. Moving a file aside
  # once it lands bounds the directory under always-on capture, and makes a
  # re-run idempotent because there is nothing left to re-read. Move rather
  # than delete, so a bad ingest is recoverable. Only called on the success
  # branch of a file's ingest — never after an `{:error, _}`, which would
  # move a file whose rows never made it into the store.
  #
  # Non-bang on purpose: this runs after the file's rows already committed.
  # A filesystem hiccup here (permissions, a full disk) must not abort the
  # rest of the batch or crash the task over data that already landed
  # safely — log it and leave the file in place. The next run answers
  # `:already_ingested` for it and tries the move again (`archive_duplicate/1`).
  defp archive_ingested(path) do
    archive = Path.join(Path.dirname(path), ".ingested")

    with :ok <- File.mkdir_p(archive),
         {:ok, _dest} <- link_into(archive, path, 0),
         :ok <- File.rm(path) do
      :ok
    else
      {:error, reason} ->
        Mix.shell().error(
          "mimir_analytics.ingest: could not archive #{path} after successful ingest: #{inspect(reason)}"
        )

        :ok
    end
  end

  # A move that never overwrites. `File.rename/2` silently replaces an
  # existing target, which would destroy an older archived file with the same
  # name (the same spool ingested into a second database, or a producer
  # reusing a name). A hard link fails on an existing target instead, so the
  # file is linked under the first free name — `name.jsonl`, `name.1.jsonl`,
  # ... — and only then removed from the spool.
  defp link_into(archive, path, n) do
    dest = Path.join(archive, archived_name(Path.basename(path), n))

    case File.ln(path, dest) do
      :ok -> {:ok, dest}
      {:error, :eexist} -> link_into(archive, path, n + 1)
      {:error, _} = error -> error
    end
  end

  defp archived_name(name, 0), do: name
  defp archived_name(name, n), do: Path.rootname(name) <> ".#{n}" <> Path.extname(name)
end
