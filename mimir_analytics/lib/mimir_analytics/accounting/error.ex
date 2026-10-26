defmodule MimirAnalytics.Accounting.Error do
  @moduledoc "Closed accounting failures without producer data or transport details."
  @enforce_keys [:code]
  defstruct [:code, :field, :http_status]

  @type code ::
          :invalid_source
          | :invalid_page
          | :invalid_event
          | :unsupported_version
          | :unsupported_kind
          | :event_conflict
          | :booking_conflict
          | :inconsistent_history
          | :checkpoint_conflict
          | :http_error
          | :transport_error
          | :buffer_error
          | :storage_error
          | :commit_uncertain
  @type field ::
          :schema_version
          | :event_id
          | :kind
          | :virtual_key_id
          | :run_id
          | :request_id
          | :measurement_owner
          | :booking_version
          | :measurement_version
          | :budget_period_start
          | :recorded_at
          | :observed_at
          | :input_tokens
          | :output_tokens
          | :cache_read_input_tokens
          | :cache_creation_input_tokens
          | :input_token_basis
          | :model
          | :model_source
          | :quoted_cost_microdollars
          | :booked_total_microdollars
          | :delta_microdollars
          | :authority
          | :complete
          | :in_flight
          | :priceability
          | :charge_state
          | :execution_outcome
          | :error_class
          | :source_id
          | :api_version
          | :rows
          | :limit
          | :next_cursor
          | :from_cursor
          | :cursor
          | :page_digest
          | :endpoint
          | :digest
          | :source_file
          | :history
          | :latest
          | nil
  @type t :: %__MODULE__{code: code(), field: field(), http_status: integer() | nil}
  @codes [
    "invalid_source",
    "invalid_page",
    "invalid_event",
    "unsupported_version",
    "unsupported_kind",
    "event_conflict",
    "booking_conflict",
    "inconsistent_history",
    "checkpoint_conflict",
    "http_error",
    "transport_error",
    "buffer_error",
    "storage_error",
    "commit_uncertain"
  ]
  @fields [
    "schema_version",
    "event_id",
    "kind",
    "virtual_key_id",
    "run_id",
    "request_id",
    "measurement_owner",
    "booking_version",
    "measurement_version",
    "budget_period_start",
    "recorded_at",
    "observed_at",
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "input_token_basis",
    "model",
    "model_source",
    "quoted_cost_microdollars",
    "booked_total_microdollars",
    "delta_microdollars",
    "authority",
    "complete",
    "in_flight",
    "priceability",
    "charge_state",
    "execution_outcome",
    "error_class",
    "source_id",
    "api_version",
    "rows",
    "limit",
    "next_cursor",
    "from_cursor",
    "cursor",
    "page_digest",
    "endpoint",
    "digest",
    "source_file",
    "history",
    "latest"
  ]
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_error}
  def new(%{code: code} = attrs) do
    field = Map.get(attrs, :field)
    status = Map.get(attrs, :http_status)

    if is_atom(code) and Atom.to_string(code) in @codes and
         (is_nil(field) or (is_atom(field) and Atom.to_string(field) in @fields)) and
         (is_nil(status) or is_integer(status)) do
      {:ok, %__MODULE__{code: code, field: field, http_status: status}}
    else
      {:error, :invalid_error}
    end
  end

  def new(_), do: {:error, :invalid_error}
  @spec result(code(), field()) :: {:error, t()}
  def result(code, field \\ nil) do
    {:ok, error} = new(%{code: code, field: field})
    {:error, error}
  end
end
