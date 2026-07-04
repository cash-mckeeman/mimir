defmodule Mimir.Catalog do
  @moduledoc """
  The routable universe: config-sourced entries (`:mimir, :catalog`) joining a
  model with the routing metadata the oracle filters on — lane, runtime,
  capabilities, latency, priority. Config-first by design; richer sourcing can
  replace the source without touching the oracle.

  Model resolution is a seam: pass `resolve: fun` to validate or enrich each
  entry's model through your own registry (`Entry.model_spec` holds whatever
  the resolver returns — this library treats it as opaque). The default
  resolver accepts the model string as its own spec.
  """
  require Logger

  defmodule Entry do
    @moduledoc "One routable catalog entry."

    @enforce_keys [:id, :model, :model_spec, :lane, :runtime]
    defstruct [
      :id,
      :model,
      :model_spec,
      :lane,
      :runtime,
      capabilities: [],
      p50_latency_ms: nil,
      priority: 100
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            model: String.t(),
            model_spec: term(),
            lane: String.t() | atom(),
            runtime: String.t() | atom(),
            capabilities: [atom()],
            p50_latency_ms: non_neg_integer() | nil,
            priority: integer()
          }
  end

  @type resolver :: (String.t() -> {:ok, term()} | {:error, :unknown_model})

  @spec entries([map()] | nil, keyword()) :: [Entry.t()]
  def entries(config \\ nil, opts \\ []) do
    resolve = Keyword.get(opts, :resolve, fn model -> {:ok, model} end)

    (config || Application.get_env(:mimir, :catalog, []))
    |> Enum.flat_map(&build_entry(&1, resolve))
  end

  defp build_entry(%{id: id, model: model} = raw, resolve) do
    case resolve.(model) do
      {:ok, spec} ->
        [
          %Entry{
            id: id,
            model: model,
            model_spec: spec,
            lane: raw.lane,
            runtime: raw.runtime,
            capabilities: Map.get(raw, :capabilities, []),
            p50_latency_ms: Map.get(raw, :p50_latency_ms),
            priority: Map.get(raw, :priority, 100)
          }
        ]

      {:error, :unknown_model} ->
        Logger.warning("catalog entry dropped (unresolvable model): #{inspect(raw)}")
        []
    end
  end
end
