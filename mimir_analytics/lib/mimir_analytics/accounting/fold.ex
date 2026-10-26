defmodule MimirAnalytics.Accounting.Fold do
  @moduledoc "Deterministic booking history reconstruction without treating missing history as zero."
  alias MimirAnalytics.Accounting.{Error, Event, State}
  @identity ~w(source_id virtual_key_id run_id request_id measurement_owner budget_period_start)a
  @spec build(nonempty_list(Event.t())) :: {:ok, State.t()} | {:error, Error.t()}
  def build([%Event{} | _] = events) do
    with :ok <- unique(events, :event_id, :event_conflict),
         :ok <- unique(events, :booking_version, :booking_conflict) do
      ordered = events |> Enum.uniq() |> Enum.sort_by(& &1.booking_version)

      if consistent?(ordered) do
        latest = List.last(ordered)
        missing = gaps(ordered)

        State.new(%{
          latest: latest,
          original_period: latest.budget_period_start,
          history: if(missing == [], do: :complete, else: {:missing_versions, missing}),
          booked_total_microdollars:
            if(missing == [], do: Enum.sum(Enum.map(ordered, & &1.delta_microdollars)))
        })
      else
        Error.result(:inconsistent_history)
      end
    end
  end

  def build(_), do: Error.result(:inconsistent_history)

  defp unique(events, field, code) do
    if events
       |> Enum.group_by(&Map.fetch!(&1, field))
       |> Enum.all?(fn {_, group} -> length(Enum.uniq(group)) == 1 end),
       do: :ok,
       else: Error.result(code)
  end

  defp consistent?([first | _] = events) do
    Enum.all?(events, fn event ->
      Map.take(event, @identity) == Map.take(first, @identity) and valid_kind?(event)
    end) and
      events
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] ->
        b.measurement_version > a.measurement_version and
          (b.booking_version != a.booking_version + 1 or
             b.booked_total_microdollars - a.booked_total_microdollars == b.delta_microdollars)
      end)
  end

  defp valid_kind?(%{booking_version: 1, kind: :initial} = e),
    do: e.delta_microdollars == e.booked_total_microdollars

  defp valid_kind?(%{booking_version: n, kind: :correction}) when n > 1, do: true
  defp valid_kind?(_), do: false

  defp gaps(events) do
    {_, ranges} =
      Enum.reduce(events, {0, []}, fn event, {previous, ranges} ->
        next = event.booking_version

        {next,
         if(next > previous + 1, do: [Range.new(previous + 1, next - 1) | ranges], else: ranges)}
      end)

    Enum.reverse(ranges)
  end
end
