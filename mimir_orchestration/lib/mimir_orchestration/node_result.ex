defmodule MimirOrchestration.NodeResult do
  @moduledoc """
  Agent result envelope returned by `AgentRunner.run/3`.

  Common fields are projected by the adapter; `raw` retains the provider's
  complete result. `stop_reason` is a provider-native value. The RMA adapter
  converts atom stop reasons to strings and preserves other values.
  """

  @enforce_keys [:text, :raw]
  defstruct [:text, :terminal, :stop_reason, :raw, usage: %{}]

  @typedoc """
  Usage projections may carry input/output counts, optional cache-read/cache-creation counts, an input-token basis and a completeness flag. Missing measurements remain missing. The adapter's raw result retains provider execution facts.
  """
  @type usage :: %{optional(String.t()) => non_neg_integer() | nil | String.t() | boolean()}

  @type t :: %__MODULE__{
          text: String.t() | nil,
          terminal: String.t() | nil,
          stop_reason: term(),
          usage: usage(),
          raw: term()
        }
end
