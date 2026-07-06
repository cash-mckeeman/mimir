defmodule Mimir.Ingest do
  @moduledoc """
  Decision-correlated ingestion of raw agent-session events into
  `Mimir.TurnEvents`. Targets RMA's documented plain-data event maps — raw
  provider events plus the synthetic `"rma.text_delta"` — but accepts any
  binary-keyed `%{"type" => ...}` map. No RMA types.

  Build a context with `new/1` or `from_route/2`, then call `handle_event/2`
  from your session handler's event hook. Each ingested event lands in the
  TurnEvents buffer keyed by `request_id`, with the decision correlation
  merged into its gen_ai map — the same buffer the embedder drains
  (`Mimir.TurnEvents.take/1`) when it meters the run.
  """

  alias Mimir.TurnEvents

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
  binary-keyed map merged into every ingested event's gen_ai payload.
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
  Ingest one raw event map. Always returns `:ok`; never raises into the
  session loop.
  """
  @spec handle_event(t(), map()) :: :ok
  def handle_event(%__MODULE__{} = ctx, event) when is_map(event) do
    case classify(event) do
      :skip -> :ok
      {type, gen_ai} -> TurnEvents.append(ctx.request_id, type, correlate(gen_ai, ctx))
    end
  rescue
    e ->
      # Never raise into the session loop, but keep the failure observable — a
      # blanket swallow would hide a genuine fault in the ingestion path.
      Logger.warning("Mimir.Ingest dropped an event: #{Exception.message(e)}")
      :ok
  end

  def handle_event(%__MODULE__{}, _event), do: :ok

  defp classify(%{"type" => "rma.text_delta", "text" => text}),
    do: {"text_delta", %{"gen_ai.output.text.delta" => text}}

  defp classify(%{"type" => type} = e) when is_binary(type),
    do: {type, Map.delete(e, "type")}

  defp classify(_), do: :skip

  defp correlate(gen_ai, ctx) do
    gen_ai
    |> Map.merge(ctx.metadata)
    |> maybe_put("decision_id", ctx.decision_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
