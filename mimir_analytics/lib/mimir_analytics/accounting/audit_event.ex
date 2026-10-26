defmodule MimirAnalytics.Accounting.AuditEvent do
  @moduledoc "Immutable nonspend export observations with source-scoped canonical identity."
  alias MimirAnalytics.Accounting.{Error, LifecycleFacts, RoutingFacts, Source}
  alias MimirAnalytics.{Mapper, Store}

  @fields ~w(schema_version event_id kind virtual_key_id run_id request_id recorded_at observed_at workflow_id step_id parent_step_id facts)a
  @enforce_keys [:source_id | @fields]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_id: String.t(),
          schema_version: 2,
          event_id: String.t(),
          kind: :routing | :lifecycle,
          virtual_key_id: String.t(),
          run_id: String.t() | nil,
          request_id: String.t(),
          recorded_at: String.t(),
          observed_at: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          parent_step_id: String.t() | nil,
          facts: RoutingFacts.t() | LifecycleFacts.t()
        }
  @spec new(Mapper.source_map(), Source.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(wire, %Source{} = source) when is_map(wire) do
    cond do
      wire["schema_version"] !== 2 ->
        Error.result(:unsupported_version, :schema_version)

      wire["kind"] not in ["routing", "lifecycle"] ->
        Error.result(:unsupported_kind, :kind)

      MapSet.new(Map.keys(wire)) != MapSet.new(Enum.map(@fields, &Atom.to_string/1)) ->
        Error.result(:invalid_event)

      true ->
        parse(wire, source)
    end
  end

  def new(_, _), do: Error.result(:invalid_event)

  defp parse(wire, source) do
    result =
      Enum.reduce_while(@fields -- [:facts], {:ok, %{source_id: source.source_id}}, fn field,
                                                                                       {:ok,
                                                                                        attrs} ->
        case value(field, Map.fetch!(wire, Atom.to_string(field))) do
          {:ok, value} -> {:cont, {:ok, Map.put(attrs, field, value)}}
          :error -> {:halt, Error.result(:invalid_event, field)}
        end
      end)

    with {:ok, attrs} <- result, {:ok, facts} <- facts(attrs.kind, wire["facts"]) do
      event = struct!(__MODULE__, Map.put(attrs, :facts, facts))

      if event.kind == :routing == is_nil(event.run_id),
        do: {:ok, event},
        else: Error.result(:invalid_event, :run_id)
    end
  end

  defp facts(:routing, wire), do: RoutingFacts.new(wire)
  defp facts(:lifecycle, wire), do: LifecycleFacts.new(wire)
  defp value(:schema_version, 2), do: {:ok, 2}
  defp value(:kind, "routing"), do: {:ok, :routing}
  defp value(:kind, "lifecycle"), do: {:ok, :lifecycle}

  defp value(field, nil) when field in [:run_id, :workflow_id, :step_id, :parent_step_id],
    do: {:ok, nil}

  defp value(field, value)
       when field in [:event_id, :virtual_key_id, :run_id] and is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: {:ok, String.downcase(value)},
      else: :error
  end

  defp value(field, value)
       when field in [:request_id, :workflow_id, :step_id, :parent_step_id] and is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: {:ok, value}, else: :error
  end

  defp value(field, value) when field in [:recorded_at, :observed_at] and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} ->
        {:ok,
         date |> Map.put(:microsecond, {elem(date.microsecond, 0), 6}) |> DateTime.to_iso8601()}

      _ ->
        :error
    end
  end

  defp value(_, _), do: :error
  @spec source_ref(t()) :: String.t()
  def source_ref(%__MODULE__{kind: :routing, facts: %RoutingFacts{decision_id: id}}),
    do: "routing:" <> id

  def source_ref(%__MODULE__{kind: :lifecycle, run_id: id}),
    do: "lifecycle:" <> id <> ":run_returned"

  @spec to_wire(t()) :: Mapper.source_map()
  def to_wire(%__MODULE__{} = event) do
    Map.new(@fields, fn field -> {Atom.to_string(field), wire_value(Map.fetch!(event, field))} end)
  end

  defp wire_value(%RoutingFacts{} = facts), do: RoutingFacts.to_wire(facts)
  defp wire_value(%LifecycleFacts{} = facts), do: LifecycleFacts.to_wire(facts)
  defp wire_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp wire_value(value), do: value
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = event) do
    wire = to_wire(event)
    # Ordered pairs include nested fact keys, independent of JSON object ordering.
    facts = wire["facts"] |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)

    [
      event.source_id
      | Enum.map(@fields, fn field ->
          if field == :facts, do: facts, else: Map.fetch!(wire, Atom.to_string(field))
        end)
    ]
    |> Jason.encode!()
    |> Store.digest()
  end
end
