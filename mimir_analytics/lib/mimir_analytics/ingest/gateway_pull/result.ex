defmodule MimirAnalytics.Ingest.GatewayPull.Result do
  @moduledoc "Published accounting buffers and the database-acknowledged cursor."
  alias MimirAnalytics.Accounting.Error
  @enforce_keys [:files, :last_cursor]
  defstruct @enforce_keys
  @type t :: %__MODULE__{files: [Path.t()], last_cursor: String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{files: files, last_cursor: cursor})
      when is_list(files) and is_binary(cursor) and byte_size(cursor) in 1..256 do
    if Enum.all?(files, &is_binary/1) and String.valid?(cursor),
      do: {:ok, %__MODULE__{files: files, last_cursor: cursor}},
      else: Error.result(:invalid_page)
  end

  def new(_), do: Error.result(:invalid_page)
end
