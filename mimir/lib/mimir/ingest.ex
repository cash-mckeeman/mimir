defmodule Mimir.Ingest do
  @moduledoc """
  Decision-correlated ingestion of raw agent-session events into
  `Mimir.TurnEvents`. Targets RMA's documented plain-data event maps — raw
  provider events plus the synthetic `"rma.text_delta"` — but accepts any
  binary-keyed `%{"type" => ...}` map. No RMA types.

  Build a context with `new/1` or `from_route/2`, then call `handle_event/2`
  from your session handler's event hook. Each recognized raw map is
  promoted to a `Mimir.Event` (domain `:llm` — RMA telemetry ingested through
  this path is model-turn-shaped; agent-session-lifecycle framing belongs to
  the gateway Collector's `agent.*` path, not this one) and appended to the
  buffer keyed by `request_id` — the same buffer the embedder drains
  (`Mimir.TurnEvents.take/1`) when it meters the run.

  `metadata`'s `"workflow_id"`/`"step_id"` keys are unchanged from before —
  they now thread straight into the ingested event's typed `workflow_id`/
  `step_id` fields (same names, promoted to `Mimir.Event`'s correlation
  spine) instead of being merged into a loose payload map. `decision_id` has
  no dedicated `Mimir.Event` field, so it rides in the event's `raw`
  carve-out, alongside the original provider-native payload.

  ## Classification

  Raw frames are matched by **structure**, not by an open-ended list of
  provider type strings:

    * A map carrying a string `"name"` (the tool-use family — `tool_use`,
      `custom_tool_use`, `server_tool_use`, `mcp_tool_use`, ... — whatever the
      provider calls it, id+name is the shape) promotes to
      `Event.llm(:tool_call, tool: %{id: ..., name: ...}, ...)`. `"id"` rides
      through as-is, including `nil` — matching the retired
      `Mimir.TurnEvents.GenAI.tool_use/1`'s tolerance for a missing call id.
    * A map carrying integer `"input_tokens"`/`"output_tokens"` promotes to
      `Event.llm(:usage, usage: %{input_tokens: ..., output_tokens: ...}, ...)`.
    * The synthetic `"rma.text_delta"` promotes to `Event.llm(:turn_complete,
      ...)` — recognized, but the closed `llm` vocabulary has no dedicated
      shape for a text delta, the same posture `Mimir.Event.OTel` documents
      for `request_start`/`request_stop`/`turn_complete`/`exception`: no fixed
      attribute shape, `raw` rendered verbatim at the export edge.
    * Anything else with a binary `"type"` is **genuinely unrecognized**:
      no event is emitted (never a placeholder type), a
      `[:mimir, :ingest, :unknown_event]` telemetry count fires, and the drop
      is logged at `:debug`.
    * Anything without a usable `"type"` (missing, or not a binary) is
      silently skipped, as before.

  Every recognized event's `raw` carve-out keeps the original map verbatim
  (minus `"type"`, which is stamped back in as `"raw_type"`) — classification
  never discards the provider-native payload, it only promotes what it
  recognizes into typed commons alongside it.
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
  Ingest one raw event map. Recognized shapes are promoted to a `Mimir.Event`
  and appended to the buffer under `ctx.request_id`; genuinely unrecognized
  shapes are counted and dropped (see the moduledoc's "Classification"
  section). Always returns `:ok`; never raises into the session loop.
  """
  @spec handle_event(t(), map()) :: :ok
  def handle_event(%__MODULE__{} = ctx, event) when is_map(event) do
    case classify(event) do
      :skip ->
        :ok

      {:unknown, raw_type} ->
        :telemetry.execute([:mimir, :ingest, :unknown_event], %{count: 1}, %{raw_type: raw_type})
        Logger.debug("Mimir.Ingest: dropped unrecognized event type #{inspect(raw_type)}")
        :ok

      {type, raw_type, attrs, event_attrs} ->
        {:ok, ev} =
          Event.llm(
            type,
            event_attrs ++
              [
                request_id: ctx.request_id,
                workflow_id: ctx.metadata["workflow_id"],
                step_id: ctx.metadata["step_id"],
                raw: correlate(raw_type, attrs, ctx)
              ]
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
    do: {:turn_complete, "text_delta", %{"output_text_delta" => text}, []}

  defp classify(%{"type" => type, "name" => name} = e)
       when is_binary(type) and is_binary(name) do
    {:tool_call, type, Map.delete(e, "type"), [tool: %{id: e["id"], name: name}]}
  end

  defp classify(%{"type" => type, "input_tokens" => input, "output_tokens" => output} = e)
       when is_binary(type) and is_integer(input) and is_integer(output) do
    {:usage, type, Map.delete(e, "type"), [usage: %{input_tokens: input, output_tokens: output}]}
  end

  defp classify(%{"type" => type}) when is_binary(type), do: {:unknown, type}

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
