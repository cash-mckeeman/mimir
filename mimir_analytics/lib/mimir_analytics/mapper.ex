defmodule MimirAnalytics.Mapper do
  @moduledoc """
  Shared ingest behaviour for session, evaluation and gateway files.
  Summaries count rows by table; already-ingested and rejected contents
  return their corresponding status atoms.
  """

  alias MimirAnalytics.Store

  @typedoc "Rows written per table this ingest touched, keyed by table name."
  @type summary :: %{rows: %{String.t() => non_neg_integer()}}

  @typedoc """
  A decoded-JSON boundary value: `Jason.decode!/1` output, before any
  `Row.*.new/1` coercion. Mappers narrow this to typed `Row.t()` structs at
  the edge; nothing past that boundary should carry a bare source map.
  """
  @type source_map :: %{optional(String.t()) => term()}

  @doc """
  Ingest one source file (or, for mappers that accept directories, a
  directory of them) into `store`. Idempotent by file contents: re-ingesting
  contents the ledger already holds, under any name, returns
  `:already_ingested` without touching the store. A mapper that records
  rejections returns `:already_rejected` for contents it rejected before.
  """
  @callback ingest(store :: Store.t(), path_or_dir :: Path.t()) ::
              {:ok, summary()} | :already_ingested | :already_rejected | {:error, term()}
end
