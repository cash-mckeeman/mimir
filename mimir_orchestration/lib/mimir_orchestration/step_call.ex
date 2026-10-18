defmodule MimirOrchestration.StepCall do
  @moduledoc """
  One dispatch, handed to the `:run` MFA as its first argument: the step's `target`,
  its resolved `input`, and the `opts` the runner built for this call.

  Routed steps carry `opts[:binding]`; adapters bind their target before applying
  execution controls. Unrouted steps retain their explicitly supplied options.
  """
  @enforce_keys [:target, :input, :opts]
  defstruct [:target, :input, :opts]
  @type t :: %__MODULE__{target: term(), input: term(), opts: keyword()}
end
