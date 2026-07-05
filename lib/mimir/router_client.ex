defmodule Mimir.RouterClient do
  @moduledoc """
  Behaviour for routing oracle clients. Two implementations are provided:

  - An in-process implementation — e.g. an in-process pipeline in a gateway,
    no HTTP hop. Use in-process when the caller already runs inside the same
    application.
  - `Mimir.RouterClient.HTTP` — Req-based POST to `GET /v1/route`.
    Use from external services or when process isolation is required.

  Both implementations return IDENTICAL atom-keyed response shapes for identical
  logical inputs.
  """

  @doc """
  Route a workload descriptor.

  - `request` — map with descriptor fields (see `Mimir.Descriptor.parse/1`).
    May include `workflow_id`, `step_id`, `parent_step_id` correlation ids.
  - `opts` — implementation-specific options:
    - in-process: e.g. `:caller_key` — a key already authorized.
    - `HTTP`: `:base_url` (required), `:bearer_token` (required).

  Returns `{:ok, response_map}` with atom keys on success, or `{:error, term()}`.
  """
  @callback route(map(), keyword()) :: {:ok, map()} | {:error, term()}
end
