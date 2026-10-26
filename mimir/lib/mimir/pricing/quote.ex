defmodule Mimir.Pricing.Quote do
  @moduledoc """
  A pricing result retaining its validated measurements. Only priced quotes carry
  an integer microdollar cost; incomplete and unpriced quotes carry `nil`.
  """

  alias Mimir.Pricing.Input

  @fields [:model, :input, :status, :cost_microdollars]
  @enforce_keys @fields
  defstruct @fields

  @type reason ::
          :not_a_map
          | :unknown_key
          | {:field, :model | :input | :status | :cost_microdollars}
  @type t :: %__MODULE__{
          model: String.t(),
          input: Input.t(),
          status: :priced | :unpriced | :incomplete,
          cost_microdollars: non_neg_integer() | nil
        }

  @doc """
  Validates atom-keyed constructor attributes, including the input through
  `Input.new/1`. Priced and unpriced statuses require eligible measurements;
  incomplete requires a missing fact or blocker. Violations return tagged errors.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:invalid_pricing_quote, reason()}}
  def new(%__MODULE__{} = quote), do: new(Map.delete(quote, :__struct__))

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_required(attrs),
         :ok <- validate_model(attrs.model),
         {:ok, input} <- validate_input(attrs.input),
         :ok <- validate_status(attrs.status),
         :ok <- validate_cost(attrs.status, attrs.cost_microdollars),
         :ok <- validate_eligibility(attrs.status, input) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :input, input))}
    end
  end

  def new(_attrs), do: error(:not_a_map)

  defp validate_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)), do: :ok, else: error(:unknown_key)
  end

  defp validate_required(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> error({:field, field})
    end
  end

  defp validate_model(model) when is_binary(model) and byte_size(model) > 0, do: :ok
  defp validate_model(_model), do: error({:field, :model})

  defp validate_input(input) do
    case Input.new(input) do
      {:ok, input} -> {:ok, input}
      {:error, _reason} -> error({:field, :input})
    end
  end

  defp validate_status(status) when status in [:priced, :unpriced, :incomplete], do: :ok
  defp validate_status(_status), do: error({:field, :status})

  defp validate_cost(:priced, cost) when is_integer(cost) and cost >= 0, do: :ok
  defp validate_cost(status, nil) when status in [:unpriced, :incomplete], do: :ok
  defp validate_cost(_status, _cost), do: error({:field, :cost_microdollars})

  defp validate_eligibility(status, input) do
    if Input.priceable?(input) == (status != :incomplete),
      do: :ok,
      else: error({:field, :status})
  end

  defp error(reason), do: {:error, {:invalid_pricing_quote, reason}}
end
