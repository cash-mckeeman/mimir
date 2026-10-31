defmodule MimirAnalytics.Accounting.FoldTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{Event, Fold, Source, State}

  defp events do
    {:ok, source} = Source.new(%{source_id: "test:gateway", api_version: 2})

    "test/support/accounting/producer.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("rows")
    |> Enum.take(3)
    |> Enum.map(fn row ->
      {:ok, event} = Event.new(row, source)
      event
    end)
  end

  test "all permutations fold deltas and retain newest facts" do
    [a, b, c] = events()

    for list <- [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] do
      assert {:ok, state} = Fold.build(list)
      assert state.history == :complete
      assert state.booked_total_microdollars == 70
      assert state.latest == c
    end
  end

  test "missing history is compact and never claims an applied total" do
    [a, b, c] = events()

    assert {:ok, %{history: {:missing_versions, [1..2]}, booked_total_microdollars: nil}} =
             Fold.build([c])

    assert {:ok, %{history: {:missing_versions, [2..2]}, booked_total_microdollars: nil}} =
             Fold.build([a, c])

    assert {:ok, %{history: {:missing_versions, [1..999_999_999]}}} =
             Fold.build([%{b | booking_version: 1_000_000_000}])
  end

  test "reject conflicting immutable identities and inconsistent histories" do
    [a, b, c] = events()
    assert {:error, %{code: :event_conflict}} = Fold.build([a, %{a | observed_at: c.recorded_at}])
    assert {:error, %{code: :booking_conflict}} = Fold.build([a, %{a | event_id: b.event_id}])

    assert {:error, %{code: :inconsistent_history}} =
             Fold.build([a, %{b | delta_microdollars: -19}])

    assert {:error, %{code: :inconsistent_history}} =
             Fold.build([a, %{b | measurement_version: 6}])
  end

  test "state constructor rejects contradictory complete total and impossible gaps" do
    [a, _, c] = events()

    assert {:error, %{code: :inconsistent_history}} =
             State.new(%{
               latest: a,
               original_period: a.budget_period_start,
               history: :complete,
               booked_total_microdollars: 0
             })

    assert {:error, %{code: :inconsistent_history}} =
             State.new(%{
               latest: c,
               original_period: c.budget_period_start,
               history: {:missing_versions, [1..3]},
               booked_total_microdollars: nil
             })
  end
end
