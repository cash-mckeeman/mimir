defmodule MimirAnalytics.Accounting.Event do
  @moduledoc "Validated accounting snapshots; nullable facts retain their producer meaning."
  alias MimirAnalytics.Accounting.{Error, Source}
  alias MimirAnalytics.{Mapper, Store}

  @fields ~w(schema_version event_id kind virtual_key_id run_id request_id measurement_owner booking_version measurement_version budget_period_start recorded_at observed_at input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens input_token_basis model model_source quoted_cost_microdollars booked_total_microdollars delta_microdollars authority complete in_flight priceability charge_state execution_outcome error_class)a
  @enforce_keys [:source_id | @fields]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_id: String.t(),
          schema_version: 2,
          event_id: String.t(),
          kind: :initial | :correction,
          virtual_key_id: String.t(),
          run_id: String.t(),
          request_id: String.t(),
          measurement_owner: :host | :http | :wire,
          booking_version: pos_integer(),
          measurement_version: pos_integer(),
          budget_period_start: String.t(),
          recorded_at: String.t(),
          observed_at: String.t(),
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_input_tokens: non_neg_integer() | nil,
          cache_creation_input_tokens: non_neg_integer() | nil,
          input_token_basis: :inclusive | :uncached | :unknown,
          model: String.t() | nil,
          model_source: :binding | :completion | :wire | :registry | :caller | :unknown,
          quoted_cost_microdollars: non_neg_integer() | nil,
          booked_total_microdollars: non_neg_integer(),
          delta_microdollars: integer(),
          authority:
            :session_result
            | :partial_result
            | :wire
            | :no_provider_work
            | :unknown
            | :lifecycle_only,
          complete: boolean(),
          in_flight: :none | :unknown,
          priceability: :priced | :unpriced | :incomplete | :not_applicable,
          charge_state: :settled | :provisional | :unreconciled | :lifecycle_only,
          execution_outcome: :ok | :error | :unknown,
          error_class:
            :provider_error
            | :transport_error
            | :timeout
            | :cancelled
            | :validation_error
            | :unknown
            | nil
        }
  @enums %{
    kind: %{"initial" => :initial, "correction" => :correction},
    measurement_owner: %{"host" => :host, "http" => :http, "wire" => :wire},
    authority: %{
      "session_result" => :session_result,
      "partial_result" => :partial_result,
      "wire" => :wire,
      "no_provider_work" => :no_provider_work,
      "unknown" => :unknown,
      "lifecycle_only" => :lifecycle_only
    },
    execution_outcome: %{"ok" => :ok, "error" => :error, "unknown" => :unknown},
    model_source: %{
      "binding" => :binding,
      "completion" => :completion,
      "wire" => :wire,
      "registry" => :registry,
      "caller" => :caller,
      "unknown" => :unknown
    },
    input_token_basis: %{
      "inclusive" => :inclusive,
      "uncached" => :uncached,
      "unknown" => :unknown
    },
    in_flight: %{"none" => :none, "unknown" => :unknown},
    priceability: %{
      "priced" => :priced,
      "unpriced" => :unpriced,
      "incomplete" => :incomplete,
      "not_applicable" => :not_applicable
    },
    charge_state: %{
      "settled" => :settled,
      "provisional" => :provisional,
      "unreconciled" => :unreconciled,
      "lifecycle_only" => :lifecycle_only
    },
    error_class: %{
      "provider_error" => :provider_error,
      "transport_error" => :transport_error,
      "timeout" => :timeout,
      "cancelled" => :cancelled,
      "validation_error" => :validation_error,
      "unknown" => :unknown
    }
  }
  @nullable ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens quoted_cost_microdollars)a
  @max 9_223_372_036_854_775_807
  @spec new(Mapper.source_map(), Source.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(wire, %Source{} = source) when is_map(wire) do
    cond do
      wire["schema_version"] !== 2 ->
        Error.result(:unsupported_version, :schema_version)

      wire["kind"] not in ["initial", "correction"] ->
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
      Enum.reduce_while(@fields, {:ok, %{source_id: source.source_id}}, fn field, {:ok, acc} ->
        case value(field, Map.fetch!(wire, Atom.to_string(field))) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
          :error -> {:halt, Error.result(:invalid_event, field)}
        end
      end)

    with {:ok, attrs} <- result do
      event = struct!(__MODULE__, attrs)
      if coherent?(event), do: {:ok, event}, else: Error.result(:invalid_event)
    end
  end

  defp value(:schema_version, 2), do: {:ok, 2}

  defp value(field, nil) when field in @nullable or field in [:model, :error_class],
    do: {:ok, nil}

  defp value(field, value)
       when field in [:event_id, :virtual_key_id, :run_id] and is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: {:ok, String.downcase(value)},
      else: :error
  end

  defp value(field, value) when field in [:request_id, :model] and is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: {:ok, value}, else: :error
  end

  defp value(field, value)
       when field in [:booking_version, :measurement_version] and is_integer(value) and value > 0 and
              value <= @max,
       do: {:ok, value}

  defp value(field, value) when field in @nullable or field == :booked_total_microdollars do
    if is_integer(value) and value >= 0 and value <= @max, do: {:ok, value}, else: :error
  end

  defp value(:delta_microdollars, value)
       when is_integer(value) and value >= -@max - 1 and value <= @max, do: {:ok, value}

  defp value(:complete, value) when is_boolean(value), do: {:ok, value}

  defp value(:budget_period_start, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> :error
    end
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

  defp value(field, value) do
    case Map.fetch(Map.get(@enums, field, %{}), value) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  defp coherent?(e) do
    (e.model != nil or e.model_source == :unknown) and
      partition?(e) and quote?(e) and authority?(e)
  end

  defp authority?(e) do
    not (e.authority == :unknown and e.complete) and no_work?(e) and
      e.authority in [:no_provider_work, :lifecycle_only] == (e.priceability == :not_applicable) and
      lifecycle?(e)
  end

  defp lifecycle?(%{authority: :lifecycle_only} = e),
    do: e.charge_state == :lifecycle_only and e.booked_total_microdollars == 0

  defp lifecycle?(e), do: e.charge_state != :lifecycle_only

  defp partition?(%{input_token_basis: :inclusive, input_tokens: input} = e)
       when is_integer(input),
       do:
         Enum.sum(
           Enum.reject([e.cache_read_input_tokens, e.cache_creation_input_tokens], &is_nil/1)
         ) <= input

  defp partition?(_), do: true

  defp quote?(%{priceability: :priced} = e),
    do:
      is_integer(e.quoted_cost_microdollars) and
        (e.charge_state != :settled or e.booked_total_microdollars == e.quoted_cost_microdollars)

  defp quote?(e), do: is_nil(e.quoted_cost_microdollars)

  defp no_work?(%{authority: :no_provider_work} = e),
    do:
      e.charge_state == :settled and e.booked_total_microdollars == 0 and e.complete and
        e.input_token_basis == :uncached and e.in_flight == :none and
        Enum.all?(
          [
            e.input_tokens,
            e.output_tokens,
            e.cache_read_input_tokens,
            e.cache_creation_input_tokens
          ],
          &(&1 == 0)
        )

  defp no_work?(_), do: true

  @spec to_wire(t()) :: Mapper.source_map()
  def to_wire(%__MODULE__{} = event) do
    Map.new(@fields, fn field ->
      value = Map.fetch!(event, field)

      {Atom.to_string(field),
       if(is_atom(value) and value not in [nil, true, false],
         do: Atom.to_string(value),
         else: value
       )}
    end)
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = event) do
    wire = to_wire(event)

    [event.source_id | Enum.map(@fields, &Map.fetch!(wire, Atom.to_string(&1)))]
    |> Jason.encode!()
    |> Store.digest()
  end
end
