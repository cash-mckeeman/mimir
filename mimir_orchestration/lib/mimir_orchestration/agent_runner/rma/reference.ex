defmodule MimirOrchestration.AgentRunner.RMA.Reference do
  @moduledoc """
  An execution target for the default RMA agent adapter.

  `provider` is an RMA provider module; `runtime` is the host's exact runtime label.
  `configured_model` is a catalog model ID for a fixed-model target. `resource` is
  an opaque provider spec or handle tagged with `:spec` or `:handle`.

  References cross the executor's plain-data boundary. Resolve credentials in the
  host; do not store a routed Binding in a reference.
  """

  @fields [:provider, :runtime, :resource, :configured_model]
  @enforce_keys [:provider, :runtime, :resource]
  defstruct [:provider, :runtime, :resource, :configured_model]

  @typedoc "Provider-owned spec or handle; its internal shape is opaque to Orchestration."
  @type resource :: {:spec, term()} | {:handle, term()}
  @type t :: %__MODULE__{
          provider: module(),
          runtime: String.t(),
          resource: resource(),
          configured_model: String.t() | nil
        }
  @type field :: :reference | :provider | :runtime | :configured_model | :resource | :keys

  @doc "Validates a reference; returns {:error, {:invalid_agent_reference, field}} for invalid or unknown fields."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, {:invalid_agent_reference, field()}}
  def new(%__MODULE__{} = ref), do: ref |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    cond do
      not Keyword.keyword?(attrs) -> invalid(:reference)
      length(Keyword.keys(attrs)) != length(Enum.uniq(Keyword.keys(attrs))) -> invalid(:keys)
      true -> attrs |> Map.new() |> new()
    end
  end

  def new(%{} = attrs) do
    provider = attrs[:provider]
    runtime = attrs[:runtime]
    model = attrs[:configured_model]
    resource = attrs[:resource]

    cond do
      Map.keys(attrs) -- @fields != [] -> invalid(:keys)
      not is_atom(provider) or provider in [nil, true, false] -> invalid(:provider)
      not label?(runtime) -> invalid(:runtime)
      not is_nil(model) and not label?(model) -> invalid(:configured_model)
      not resource?(resource) -> invalid(:resource)
      true -> {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_other), do: invalid(:reference)

  defp resource?({tag, _value}) when tag in [:spec, :handle], do: true
  defp resource?(_other), do: false
  defp label?(value), do: is_binary(value) and value != ""
  defp invalid(field), do: {:error, {:invalid_agent_reference, field}}
end
