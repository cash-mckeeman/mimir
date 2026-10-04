defmodule MimirAnalytics.Row.ModelCall do
  @moduledoc """
  One row of `model_calls` — a gateway `"request_log"` line. `new/1` owns the
  rename off the wire shape (`request_id` → `mimir_request_id`,
  `inserted_at` → `ts`) and the usage/fallback defaults. `run_id` starts
  `nil`; `GatewayExport.resolve_run_ids/1` backfills it via
  `(workflow_id, step_id)` against `runs` after ingest.
  """

  @enforce_keys [:mimir_request_id, :source_file]
  defstruct [
    :mimir_request_id,
    :run_id,
    :workflow_id,
    :step_id,
    :parent_step_id,
    :virtual_key_id,
    :parent_key_id,
    :tenant_id,
    :lane,
    :provider,
    :model_id,
    :status,
    :finish_reason,
    :input_tokens,
    :output_tokens,
    :cost_microdollars,
    :latency_ms,
    :fallback,
    :error_class,
    :ts,
    :source_file
  ]

  @type t :: %__MODULE__{
          mimir_request_id: String.t(),
          # nullable, resolved via workflow/step
          run_id: String.t() | nil,
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          parent_step_id: String.t() | nil,
          virtual_key_id: String.t() | nil,
          parent_key_id: String.t() | nil,
          tenant_id: String.t() | nil,
          lane: String.t() | nil,
          provider: String.t() | nil,
          model_id: String.t() | nil,
          # success | error
          status: String.t() | nil,
          finish_reason: String.t() | nil,
          input_tokens: integer(),
          output_tokens: integer(),
          cost_microdollars: integer(),
          latency_ms: integer() | nil,
          fallback: boolean(),
          error_class: String.t() | nil,
          ts: String.t() | nil,
          source_file: String.t()
        }

  @doc ~s[Build a `t()` from a decoded "request_log" line plus "source_file".]
  @spec new(map()) :: t()
  def new(l) do
    %__MODULE__{
      mimir_request_id: Map.fetch!(l, "request_id"),
      run_id: nil,
      workflow_id: l["workflow_id"],
      step_id: l["step_id"],
      parent_step_id: l["parent_step_id"],
      virtual_key_id: l["virtual_key_id"],
      parent_key_id: l["parent_key_id"],
      tenant_id: l["tenant_id"],
      lane: l["lane"],
      provider: l["provider"],
      model_id: l["model_id"],
      status: l["status"],
      finish_reason: l["finish_reason"],
      input_tokens: l["input_tokens"] || 0,
      output_tokens: l["output_tokens"] || 0,
      cost_microdollars: l["cost_microdollars"] || 0,
      latency_ms: l["latency_ms"],
      fallback: l["fallback"] || false,
      error_class: l["error_class"],
      ts: l["inserted_at"],
      source_file: Map.fetch!(l, "source_file")
    }
  end
end
