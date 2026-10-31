defmodule MimirAnalytics.Accounting.Source do
  @moduledoc "An application-owned identity for one accounting issuer."
  alias MimirAnalytics.Accounting.Error
  @enforce_keys [:source_id, :api_version]
  defstruct @enforce_keys
  @type t :: %__MODULE__{source_id: String.t(), api_version: 2}
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{source_id: id, api_version: 2}) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, id),
      do: {:ok, %__MODULE__{source_id: id, api_version: 2}},
      else: Error.result(:invalid_source, :source_id)
  end

  def new(_), do: Error.result(:invalid_source)
end
