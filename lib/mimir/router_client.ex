defmodule Mimir.RouterClient do
  @moduledoc """
  Behaviour for routing oracle clients. This package ships one implementation:

  - `Mimir.RouterClient.HTTP` — Req-based POST to `/v1/route`. Use from
    external services or when process isolation is required.

  An embedder that runs in the same application as the router (e.g. an
  in-process pipeline in a gateway, no HTTP hop) may implement this behaviour
  with its own in-process client instead. Any conforming implementation
  should return an identical `{:ok, %Mimir.RouteResponse{}}` shape for
  identical logical inputs.
  """

  @doc """
  Route a workload descriptor.

  - `request` — map with descriptor fields (see `Mimir.Descriptor.parse/1`).
    May include `workflow_id`, `step_id`, `parent_step_id` correlation ids.
  - `opts` — implementation-specific options, e.g. for `HTTP`:
    `:base_url` (required), `:bearer_token` (required).

  Returns `{:ok, %Mimir.RouteResponse{}}` on success, or `{:error, term()}`.
  """
  @callback route(map(), keyword()) :: {:ok, Mimir.RouteResponse.t()} | {:error, term()}
end
