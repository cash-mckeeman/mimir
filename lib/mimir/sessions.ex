defmodule Mimir.Sessions do
  @moduledoc """
  The one canonical recipe for wiring a routed placement into an agent
  session: granted key + routed base_url into `model_config`, budget guard
  from the grant, correlation metadata for decision-linked ingestion. Produces
  a plain keyword list targeting RMA's documented session options — no RMA
  types imported.

      {:ok, resp} = Mimir.RouterClient.route(descriptor, client_opts)
      session_opts = Mimir.Sessions.opts(resp, base_url: gateway_url)
      Session.run(provider, session_opts ++ [handler: MyTools, prompt: prompt])

  `opts/2` raises `ArgumentError` on a no-candidate or malformed route
  response — fail at composition time, not mid-session. `Mimir.Guard` handles
  the mid-run side and never raises.

  The `api_key`/`base_url` pair is the data-plane half (hard enforcement at
  the gateway's budget constraint) for lanes that traverse a gateway;
  `turn_guard` is the control-plane half for runtimes the gateway cannot
  front. Both ride along on every placement; each runtime uses what applies.
  """

  @doc """
  Options:
  - `:base_url` — routed data-plane URL; defaults to
    `Application.get_env(:mimir, :gateway_base_url)`; omitted from
    `model_config` when nil (direct-to-provider runtimes).
  - `:request_id` — correlation id; defaults to `Mimir.RouteLog.gen_request_id/0`.
  - `:guard` — extra `Mimir.Guard.caps/1` options composed into the grant guard.
  """
  @spec opts(map(), keyword()) :: keyword()
  def opts(resp, opts \\ []) when is_map(resp) do
    placement =
      get(resp, :placement) ||
        raise ArgumentError,
              "route response has no placement (verdict: #{inspect(get(resp, :verdict))})"

    grant = get(resp, :grant) || raise ArgumentError, "route response has no grant"
    api_key = get(grant, :key) || raise ArgumentError, "route response grant has no key"

    model =
      get(placement, :model) || raise ArgumentError, "route response placement has no model"

    request_id = Keyword.get(opts, :request_id) || Mimir.RouteLog.gen_request_id()
    base_url = Keyword.get(opts, :base_url, Application.get_env(:mimir, :gateway_base_url))

    metadata = %{
      mimir_request_id: request_id,
      decision_id: get(resp, :decision_id),
      workflow_id: get(resp, :workflow_id),
      step_id: get(resp, :step_id)
    }

    model_config =
      %{model: model, api_key: api_key, metadata: metadata}
      |> maybe_put(:base_url, base_url)

    [
      model_config: model_config,
      turn_guard: Mimir.Guard.for_grant(grant, model, Keyword.get(opts, :guard, [])),
      telemetry_metadata: metadata
    ]
  end

  defp get(map, key) when is_map(map), do: map[key] || map[to_string(key)]
  defp get(_not_a_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
