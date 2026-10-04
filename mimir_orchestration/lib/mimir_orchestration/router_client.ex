defmodule MimirOrchestration.RouterClient do
  @moduledoc "Host routing seam: one call per routed step to select a placement and grant."
  @type request :: %{
          required(:descriptor) => map(),
          required(:workflow_id) => String.t(),
          required(:step_id) => String.t(),
          optional(:parent_step_id) => String.t() | nil,
          optional(:fanout_hint) => pos_integer(),
          # "kind:id" frames, outermost to innermost,
          # for the scopes the runner has created so far (workflow,
          # workflow_step).
          optional(:path) => [String.t()]
        }
  @callback route(request(), keyword()) :: {:ok, map()} | {:error, term()}
end
