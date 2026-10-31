defmodule MimirAnalytics.Accounting.RoutingFacts do
  @moduledoc "Placement facts describe a decision and carry no execution or charging authority."
  alias MimirAnalytics.Accounting.Error
  alias MimirAnalytics.Mapper
  @fields ~w(decision_id outcome selected_model selected_lane grant_id)a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          decision_id: String.t(),
          outcome: :placed | :grant_failed | :no_candidate,
          selected_model: String.t() | nil,
          selected_lane: String.t() | nil,
          grant_id: String.t() | nil
        }
  @outcomes %{
    "placed" => :placed,
    "grant_failed" => :grant_failed,
    "no_candidate" => :no_candidate
  }
  @spec new(Mapper.source_map()) :: {:ok, t()} | {:error, Error.t()}
  def new(wire) when is_map(wire) do
    if Enum.sort(Map.keys(wire)) == Enum.sort(Enum.map(@fields, &Atom.to_string/1)) do
      build(wire)
    else
      Error.result(:invalid_event, :facts)
    end
  end

  def new(_), do: Error.result(:invalid_event, :facts)

  defp build(wire) do
    with id when is_binary(id) <- wire["decision_id"],
         true <- Regex.match?(~r/\Ard_[a-z2-7]{26}\z/, id),
         {:ok, outcome} <- Map.fetch(@outcomes, wire["outcome"]),
         true <- optional_text?(wire["selected_model"]),
         true <- optional_text?(wire["selected_lane"]),
         {:ok, grant} <- grant(wire["grant_id"]) do
      facts = %__MODULE__{
        decision_id: id,
        outcome: outcome,
        selected_model: wire["selected_model"],
        selected_lane: wire["selected_lane"],
        grant_id: grant
      }

      if coherent?(facts), do: {:ok, facts}, else: Error.result(:invalid_event, :facts)
    else
      _ -> Error.result(:invalid_event, :facts)
    end
  end

  defp grant(nil), do: {:ok, nil}

  defp grant(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: {:ok, String.downcase(value)},
      else: :error
  end

  defp grant(_), do: :error
  defp optional_text?(nil), do: true

  defp optional_text?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp coherent?(%{outcome: :no_candidate} = facts),
    do: is_nil(facts.selected_model) and is_nil(facts.selected_lane) and is_nil(facts.grant_id)

  defp coherent?(facts),
    do:
      not is_nil(facts.selected_model) and not is_nil(facts.selected_lane) and
        facts.outcome == :placed == not is_nil(facts.grant_id)

  @spec to_wire(t()) :: Mapper.source_map()
  def to_wire(%__MODULE__{} = facts),
    do: %{
      "decision_id" => facts.decision_id,
      "outcome" => Atom.to_string(facts.outcome),
      "selected_model" => facts.selected_model,
      "selected_lane" => facts.selected_lane,
      "grant_id" => facts.grant_id
    }
end
