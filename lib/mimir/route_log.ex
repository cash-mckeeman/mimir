defmodule Mimir.RouteLog do
  @moduledoc """
  The typed record of one routing decision — who asked (`caller`), which
  workflow step (`correlation`), how it ended (`outcome`), and the decision
  record. `to_meta/2` translates it into request-log meta vocabulary; how (and
  whether) that meta is persisted belongs to the embedder.

  Outcomes: `:placed` and `:no_candidate` are both successful routing verdicts
  (`status: "success"`) — a no-candidate answer is an outcome, not an error.
  `{:grant_failed, reason}` means a placement was decided but not grantable
  (`status: "error"`, class `"grant_failed"`); the decision record survives
  the failure it explains.
  """

  alias Mimir.TurnEvents

  @lane "router"

  @enforce_keys [:request_id, :caller, :correlation, :outcome, :decision_record]
  defstruct @enforce_keys

  @typedoc "How the route call ended. Everything else about the row derives from this."
  @type outcome :: :placed | :no_candidate | {:grant_failed, reason :: atom()}

  @typedoc "The workflow coordinates of the routed step."
  @type correlation :: %{
          workflow_id: String.t(),
          step_id: String.t(),
          parent_step_id: String.t() | nil
        }

  @typedoc "Who asked — any map or struct carrying the caller key's id and tenant."
  @type caller :: %{
          :id => String.t(),
          optional(:tenant_id) => String.t() | nil,
          optional(atom()) => any()
        }

  @type t :: %__MODULE__{
          request_id: String.t(),
          caller: caller(),
          correlation: correlation(),
          outcome: outcome(),
          decision_record: map()
        }

  @doc "Correlation id for a route call that arrived without one."
  @spec gen_request_id() :: String.t()
  def gen_request_id do
    "req_route_" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc """
  Translate the record into request-log meta. Pure given `ts` (nanosecond
  event timestamp); defaults to the monotonic clock. Only route-meaningful
  keys are emitted. Notably, the emitted `virtual_key_id` carries `caller.id`
  — the field name is kept as-is for embedder request-log vocabulary
  compatibility, not because the caller is necessarily a virtual key.
  """
  @spec to_meta(t(), integer()) :: map()
  def to_meta(%__MODULE__{} = log, ts \\ System.monotonic_time(:nanosecond)) do
    %{
      request_id: log.request_id,
      virtual_key_id: log.caller.id,
      tenant_id: Map.get(log.caller, :tenant_id),
      lane: @lane,
      status: status(log.outcome),
      error_class: error_class(log.outcome),
      error_detail: error_detail(log.outcome),
      gen_ai_events: [TurnEvents.envelope(1, ts, "routing_decision", log.decision_record)],
      workflow_id: log.correlation.workflow_id,
      step_id: log.correlation.step_id,
      parent_step_id: log.correlation.parent_step_id
    }
  end

  defp status({:grant_failed, _}), do: "error"
  defp status(_placed_or_no_candidate), do: "success"

  defp error_class({:grant_failed, _}), do: "grant_failed"
  defp error_class(_), do: nil

  defp error_detail({:grant_failed, reason}), do: to_string(reason)
  defp error_detail(_), do: nil
end
