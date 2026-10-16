defmodule Mimir.Binding.Target do
  @moduledoc """
  A host's proposed execution target: its runtime label, configured model,
  per-run model capability, and data-plane wire.

  `configured_model` uses the catalog namespace (`"provider:model_id"`), like
  `Mimir.Placement.model`. The runtime library owns translation to provider-native
  models. Hosts derive capabilities from their runtime library.

  `data_plane` is `:chat_completions`, `:managed_agents_api`, or `:none` when the
  target cannot send traffic through a gateway.
  """

  @wires [:chat_completions, :managed_agents_api]
  @fields [:runtime, :configured_model, :runtime_model, :data_plane]

  @enforce_keys [:runtime, :runtime_model, :data_plane]
  defstruct [:runtime, :configured_model, :runtime_model, :data_plane]

  @type wire :: :chat_completions | :managed_agents_api

  @type t :: %__MODULE__{
          runtime: String.t(),
          configured_model: String.t() | nil,
          runtime_model: boolean(),
          data_plane: :none | wire()
        }

  @type field ::
          :runtime
          | :configured_model
          | :runtime_model
          | :data_plane
          | :not_a_map
          | {:unknown_keys, [term()]}

  @doc """
  Builds a target from an atom-keyed map, keyword list, or existing target.

  `runtime` must be a non-empty binary and is preserved verbatim.
  `configured_model` may be absent, `nil`, or a non-empty binary.
  `runtime_model` and `data_plane` are required.

  Unknown keys are refused before field validation. Invalid fields return
  `{:error, {:invalid_target, field}}` in runtime, configured model, runtime model,
  then data plane order. Other inputs return the same error with `:not_a_map`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_target, field()}}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_target, :not_a_map}}
  end

  def new(%__MODULE__{} = target), do: target |> Map.from_struct() |> new()

  def new(%{} = attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> validate(attrs)
      unknown -> {:error, {:invalid_target, {:unknown_keys, Enum.sort(unknown)}}}
    end
  end

  def new(_other), do: {:error, {:invalid_target, :not_a_map}}

  @doc "The data-plane wires a target can name, other than `:none`."
  @spec wires() :: [wire()]
  def wires, do: @wires

  defp validate(attrs) do
    runtime = Map.get(attrs, :runtime)
    model = Map.get(attrs, :configured_model)
    runtime_model = Map.get(attrs, :runtime_model)
    data_plane = Map.get(attrs, :data_plane)

    cond do
      not label?(runtime) ->
        {:error, {:invalid_target, :runtime}}

      not (is_nil(model) or label?(model)) ->
        {:error, {:invalid_target, :configured_model}}

      not is_boolean(runtime_model) ->
        {:error, {:invalid_target, :runtime_model}}

      data_plane not in [:none | @wires] ->
        {:error, {:invalid_target, :data_plane}}

      true ->
        {:ok,
         %__MODULE__{
           runtime: runtime,
           configured_model: model,
           runtime_model: runtime_model,
           data_plane: data_plane
         }}
    end
  end

  defp label?(value), do: is_binary(value) and value != ""
end
