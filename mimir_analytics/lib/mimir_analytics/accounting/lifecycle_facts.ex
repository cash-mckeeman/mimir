defmodule MimirAnalytics.Accounting.LifecycleFacts do
  @moduledoc "Local submitted-run return facts; correlation never identifies a financial booking."
  alias MimirAnalytics.Accounting.Error
  alias MimirAnalytics.Mapper
  @enforce_keys [:phase, :outcome, :session_id, :turn_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          phase: :run_returned,
          outcome: :ok | :error | :unknown,
          session_id: String.t() | nil,
          turn_id: String.t() | nil
        }
  @outcomes %{"ok" => :ok, "error" => :error, "unknown" => :unknown}
  @spec new(Mapper.source_map()) :: {:ok, t()} | {:error, Error.t()}
  def new(
        %{
          "phase" => "run_returned",
          "outcome" => outcome,
          "session_id" => session,
          "turn_id" => turn
        } = wire
      )
      when map_size(wire) == 4 do
    with {:ok, outcome} <- Map.fetch(@outcomes, outcome),
         true <- optional_text?(session) and optional_text?(turn) do
      {:ok,
       %__MODULE__{phase: :run_returned, outcome: outcome, session_id: session, turn_id: turn}}
    else
      _ -> Error.result(:invalid_event, :facts)
    end
  end

  def new(_), do: Error.result(:invalid_event, :facts)
  defp optional_text?(nil), do: true

  defp optional_text?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  @spec to_wire(t()) :: Mapper.source_map()
  def to_wire(%__MODULE__{} = facts),
    do: %{
      "phase" => "run_returned",
      "outcome" => Atom.to_string(facts.outcome),
      "session_id" => facts.session_id,
      "turn_id" => facts.turn_id
    }
end
