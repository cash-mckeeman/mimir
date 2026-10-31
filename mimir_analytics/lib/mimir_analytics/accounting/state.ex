defmodule MimirAnalytics.Accounting.State do
  @moduledoc "Latest immutable facts and the applied total justified by observed history."
  alias MimirAnalytics.Accounting.{Error, Event}
  @enforce_keys [:latest, :original_period, :history, :booked_total_microdollars]
  defstruct @enforce_keys
  @type history :: :complete | {:missing_versions, [Range.t()]}
  @type t :: %__MODULE__{
          latest: Event.t(),
          original_period: String.t(),
          history: history(),
          booked_total_microdollars: non_neg_integer() | nil
        }
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{
        latest: %Event{} = latest,
        original_period: period,
        history: history,
        booked_total_microdollars: total
      }) do
    if period == latest.budget_period_start and valid_history?(history, total, latest) do
      {:ok,
       %__MODULE__{
         latest: latest,
         original_period: period,
         history: history,
         booked_total_microdollars: total
       }}
    else
      Error.result(:inconsistent_history)
    end
  end

  def new(_), do: Error.result(:inconsistent_history)

  defp valid_history?(:complete, total, latest),
    do: is_integer(total) and total == latest.booked_total_microdollars

  defp valid_history?({:missing_versions, [_ | _] = ranges}, nil, latest) do
    Enum.all?(ranges, &valid_range?(&1, latest.booking_version)) and compact?(ranges)
  end

  defp valid_history?(_, _, _), do: false

  defp valid_range?(%Range{step: 1, first: first, last: last}, version),
    do: first > 0 and last >= first and last < version

  defp valid_range?(_, _), do: false

  defp compact?(ranges),
    do:
      ranges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> a.last + 1 < b.first end)
end
