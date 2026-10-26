defmodule MimirAnalytics.Accounting.Page do
  @moduledoc "Whole validated accounting pages; buffer receipts identify actual input bytes."
  alias MimirAnalytics.Accounting.{Error, ExportEvent, Source}
  alias MimirAnalytics.{Mapper, Store}
  @enforce_keys [:source, :from_cursor, :next_cursor, :limit, :events]
  defstruct @enforce_keys ++ [:digest, :source_file]

  @type t :: %__MODULE__{
          source: Source.t(),
          from_cursor: String.t() | nil,
          next_cursor: String.t(),
          limit: pos_integer(),
          events: [ExportEvent.t()],
          digest: String.t() | nil,
          source_file: String.t() | nil
        }
  @spec new(Mapper.source_map(), Source.t(), String.t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(
        %{"api_version" => 2, "rows" => rows, "limit" => limit, "next_cursor" => cursor},
        %Source{} = source,
        from
      )
      when is_list(rows) and is_integer(limit) and limit in 1..500 do
    if length(rows) <= limit and valid_position?(rows, from, cursor) do
      with {:ok, events} <- parse(rows, source) do
        {:ok,
         %__MODULE__{
           source: source,
           from_cursor: from,
           next_cursor: cursor,
           limit: limit,
           events: events
         }}
      end
    else
      Error.result(:invalid_page)
    end
  end

  def new(%{"api_version" => version}, _, _) when version !== 2,
    do: Error.result(:unsupported_version, :api_version)

  def new(_, _, _), do: Error.result(:invalid_page)

  defp valid_position?(rows, from, cursor),
    do: cursor?(cursor) and (is_nil(from) or cursor?(from)) and advances?(rows, from, cursor)

  defp advances?([], nil, _cursor), do: true
  defp advances?([], from, cursor), do: from == cursor
  defp advances?([_ | _], from, cursor), do: from != cursor

  defp cursor?(cursor),
    do: is_binary(cursor) and byte_size(cursor) in 1..256 and String.valid?(cursor)

  defp parse(rows, source) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case ExportEvent.new(row, source) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  @spec to_buffer(t()) :: binary()
  def to_buffer(%__MODULE__{} = p) do
    Jason.encode!(%{
      kind: "accounting_page",
      buffer_version: 1,
      source_id: p.source.source_id,
      from_cursor: p.from_cursor,
      api_version: 2,
      rows: Enum.map(p.events, &ExportEvent.to_wire/1),
      next_cursor: p.next_cursor,
      limit: p.limit
    }) <> "\n"
  end

  @spec from_buffer(binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_buffer(bytes, basename) when is_binary(bytes) and is_binary(basename) do
    with true <- basename != "" and Path.basename(basename) == basename,
         {:ok,
          %{
            "kind" => "accounting_page",
            "buffer_version" => 1,
            "source_id" => id,
            "from_cursor" => from
          } = wire} <- Jason.decode(bytes),
         {:ok, source} <- Source.new(%{source_id: id, api_version: 2}),
         {:ok, page} <- new(wire, source, from) do
      {:ok, %{page | digest: Store.digest(bytes), source_file: basename}}
    else
      {:error, %Error{}} = error -> error
      _ -> Error.result(:invalid_page)
    end
  end

  def from_buffer(_, _), do: Error.result(:invalid_page)
end
