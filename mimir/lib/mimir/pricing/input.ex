defmodule Mimir.Pricing.Input do
  @moduledoc """
  Token measurements for a pricing quote. Missing counts remain `nil`;
  inclusive input includes both cache categories, while uncached input excludes them.
  """

  @count_fields [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
  ]
  @fields @count_fields ++ [:input_token_basis, :complete?, :in_flight]
  @enforce_keys @fields
  defstruct @fields

  @type field ::
          :input_tokens
          | :output_tokens
          | :cache_read_input_tokens
          | :cache_creation_input_tokens
          | :input_token_basis
          | :complete?
          | :in_flight
  @type reason :: :not_a_map | :unknown_key | {:field, field()} | :invalid_cache_partition
  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          input_token_basis: :inclusive | :uncached | :unknown,
          complete?: boolean(),
          in_flight: :none | :unknown
        }

  @doc """
  Validates atom-keyed constructor attributes or revalidates an existing input.
  Omitted counts become `nil`; omitted basis, completeness and in-flight state
  become `:unknown`, `false` and `:unknown`. Invalid values return tagged errors.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, {:invalid_pricing_input, reason()}}
  def new(%__MODULE__{} = input) do
    attrs = Map.delete(input, :__struct__)

    with :ok <- validate_keys(attrs),
         :ok <- validate_required(attrs) do
      build(attrs)
    end
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs) do
      build(attrs)
    end
  end

  def new(_attrs), do: error(:not_a_map)

  @doc "Returns whether validated measurements are complete enough to price, independent of rates."
  @spec priceable?(t()) :: boolean()
  def priceable?(%__MODULE__{
        input_tokens: input,
        output_tokens: output,
        cache_read_input_tokens: read,
        cache_creation_input_tokens: write,
        input_token_basis: basis,
        complete?: true,
        in_flight: :none
      })
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
             is_integer(read) and read >= 0 and is_integer(write) and write >= 0 and
             basis in [:inclusive, :uncached],
      do: true

  def priceable?(%__MODULE__{}), do: false

  defp validate_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)), do: :ok, else: error(:unknown_key)
  end

  defp validate_required(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> error({:field, field})
    end
  end

  defp build(attrs) do
    defaults = %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_input_tokens: nil,
      cache_creation_input_tokens: nil,
      input_token_basis: :unknown,
      complete?: false,
      in_flight: :unknown
    }

    input = struct!(__MODULE__, Map.merge(defaults, attrs))

    with :ok <- validate_fields(input),
         :ok <- validate_partition(input) do
      {:ok, input}
    end
  end

  defp validate_fields(input) do
    case Enum.find(@fields, &(not valid_field?(&1, Map.fetch!(input, &1)))) do
      nil -> :ok
      field -> error({:field, field})
    end
  end

  defp valid_field?(field, value) when field in @count_fields,
    do: is_nil(value) or (is_integer(value) and value >= 0)

  defp valid_field?(:input_token_basis, value), do: value in [:inclusive, :uncached, :unknown]
  defp valid_field?(:complete?, value), do: is_boolean(value)
  defp valid_field?(:in_flight, value), do: value in [:none, :unknown]

  defp validate_partition(%__MODULE__{
         input_token_basis: :inclusive,
         input_tokens: input,
         cache_read_input_tokens: read,
         cache_creation_input_tokens: write
       })
       when is_integer(input) and is_integer(read) and is_integer(write) and read + write > input,
       do: error(:invalid_cache_partition)

  defp validate_partition(_input), do: :ok

  defp error(reason), do: {:error, {:invalid_pricing_input, reason}}
end
