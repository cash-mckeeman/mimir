defmodule MimirOrchestration.StepCall do
  @moduledoc """
  One dispatch, handed to the `:run` MFA as its first argument: the step's `target`,
  its resolved `input`, and the `opts` the runner built for this call (`:metadata`,
  and for a routed step `:model` and `:turn_guard`).
  """
  @enforce_keys [:target, :input, :opts]
  defstruct [:target, :input, :opts]
  @type t :: %__MODULE__{target: term(), input: term(), opts: keyword()}
end
