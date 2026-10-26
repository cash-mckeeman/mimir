defmodule MimirAnalytics.Accounting.Checkpoint do
  @moduledoc "The durable acknowledgement position of one accounting source."
  alias MimirAnalytics.Accounting.{Error, Source}
  @enforce_keys [:source_id, :api_version, :endpoint, :cursor, :page_digest]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_id: String.t(),
          api_version: 2,
          endpoint: :accounting,
          cursor: String.t() | nil,
          page_digest: String.t() | nil
        }
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{
        source_id: id,
        api_version: 2,
        endpoint: :accounting,
        cursor: cursor,
        page_digest: digest
      }) do
    with {:ok, _} <- Source.new(%{source_id: id, api_version: 2}),
         true <-
           (is_nil(cursor) and is_nil(digest)) or
             (is_binary(cursor) and byte_size(cursor) in 1..256 and is_binary(digest) and
                Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)) do
      {:ok,
       %__MODULE__{
         source_id: id,
         api_version: 2,
         endpoint: :accounting,
         cursor: cursor,
         page_digest: digest
       }}
    else
      _ -> Error.result(:checkpoint_conflict)
    end
  end

  def new(_), do: Error.result(:checkpoint_conflict)
end
