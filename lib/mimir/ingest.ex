defmodule Mimir.Ingest do
  @moduledoc """
  Decision-correlated ingestion of raw agent-session events into
  `Mimir.TurnEvents`. Targets RMA's documented plain-data event maps — raw
  provider events plus the synthetic `"rma.text_delta"` — but accepts any
  binary-keyed `%{"type" => ...}` map. No RMA types.

  Build a context with `new/1` or `from_route/2`, then call `handle_event/2`
  from your session handler's event hook. Each ingested map is promoted to a
  `Mimir.Event` (domain `:llm` — RMA telemetry ingested through this path is
  model-turn-shaped; agent-session-lifecycle framing belongs to the gateway
  Collector's `agent.*` path, not this one) and appended to the buffer keyed
  by `request_id` — the same buffer the embedder drains
  (`Mimir.TurnEvents.take/1`) when it meters the run.

  `metadata`'s `"workflow_id"`/`"step_id"` keys are unchanged from before —
  they now thread straight into the ingested event's typed `workflow_id`/
  `step_id` fields (same names, promoted to `Mimir.Event`'s correlation
  spine) instead of being merged into a loose payload map. `decision_id` has
  no dedicated `Mimir.Event` field, so it rides in the event's `raw`
  carve-out, alongside the original provider-native payload. The ingested
  event's `type` is always `:turn_complete` — the closed `llm` vocabulary has
  no dedicated shape for arbitrary provider-native passthrough, the same
  posture `Mimir.Event.OTel` documents for `request_start`/`request_stop`/
  `turn_complete`/`exception`: no fixed attribute shape, `raw` rendered
  verbatim at the export edge.
  """

  alias Mimir.{Event, TurnEvents}

  require Logger

  @enforce_keys [:request_id]
  defstruct [:request_id, :decision_id, metadata: %{}]

  @type t :: %__MODULE__{
          request_id: String.t(),
          decision_id: String.t() | nil,
          metadata: %{optional(String.t()) => term()}
        }

  @doc """
  Options: `:request_id` (required), `:decision_id`, `:metadata` — a
  binary-keyed map. `"workflow_id"`/`"step_id"` correlate into the ingested
  event's typed ids; any other key rides in `raw`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      request_id: Keyword.fetch!(opts, :request_id),
      decision_id: Keyword.get(opts, :decision_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Build a context straight from a `Mimir.RouteResponse`."
  @spec from_route(Mimir.RouteResponse.t(), String.t()) :: t()
  def from_route(%Mimir.RouteResponse{} = resp, request_id) when is_binary(request_id) do
    new(
      request_id: request_id,
      decision_id: resp.decision_id,
      metadata:
        %{"workflow_id" => resp.workflow_id, "step_id" => resp.step_id}
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
    )
  end

  @doc """
  Ingest one raw event map, promoting it to a `Mimir.Event` and appending it
  to the buffer under `ctx.request_id`. Always returns `:ok`; never raises
  into the session loop.
  """
  @spec handle_event(t(), map()) :: :ok
  def handle_event(%__MODULE__{} = ctx, event) when is_map(event) do
    case classify(event) do
      :skip ->
        :ok

      {raw_type, attrs} ->
        {:ok, ev} =
          Event.llm(:turn_complete,
            request_id: ctx.request_id,
            workflow_id: ctx.metadata["workflow_id"],
            step_id: ctx.metadata["step_id"],
            raw: correlate(raw_type, attrs, ctx)
          )

        TurnEvents.append(ctx.request_id, ev)
    end
  rescue
    e ->
      # Never raise into the session loop, but keep the failure observable — a
      # blanket swallow would hide a genuine fault in the ingestion path.
      Logger.warning("Mimir.Ingest: dropped an event: #{Exception.message(e)}")
      :ok
  end

  def handle_event(%__MODULE__{}, _event), do: :ok

  defp classify(%{"type" => "rma.text_delta", "text" => text}),
    do: {"text_delta", %{"output_text_delta" => text}}

  defp classify(%{"type" => type} = e) when is_binary(type),
    do: {type, Map.delete(e, "type")}

  defp classify(_), do: :skip

  defp correlate(raw_type, attrs, ctx) do
    attrs
    |> Map.put("raw_type", raw_type)
    |> Map.merge(Map.drop(ctx.metadata, ["workflow_id", "step_id"]))
    |> maybe_put("decision_id", ctx.decision_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
