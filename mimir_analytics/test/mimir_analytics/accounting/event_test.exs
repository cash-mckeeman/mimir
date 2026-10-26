defmodule MimirAnalytics.Accounting.EventTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{Event, Source}

  defp rows,
    do:
      "test/support/accounting/producer.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("rows")

  defp source do
    {:ok, source} = Source.new(%{source_id: "test:gateway", api_version: 2})
    source
  end

  test "actual producer rows preserve nullable complete facts and independent versions" do
    events =
      Enum.map(rows(), fn row ->
        assert {:ok, event} = Event.new(row, source())
        event
      end)

    assert Enum.map(Enum.take(events, 3), & &1.measurement_version) == [7, 9, 13]
    assert List.last(events).complete
    assert List.last(events).input_tokens == nil
    assert List.last(events).quoted_cost_microdollars == nil
    assert List.last(events).booked_total_microdollars == 0
  end

  test "canonical identity and zero offset timestamps fingerprint identically" do
    row = hd(rows())
    {:ok, a} = Event.new(row, source())

    {:ok, b} =
      Event.new(
        Map.merge(row, %{
          "event_id" => String.upcase(row["event_id"]),
          "observed_at" => "2026-09-29T10:00:00.000000+00:00"
        }),
        source()
      )

    assert a == b
    assert a.observed_at == "2026-09-29T10:00:00.000000Z"
    assert Event.fingerprint(a) == Event.fingerprint(b)
  end

  test "reject malformed identities texts counts enums and visible contradictions" do
    row = hd(rows())

    for {key, value} <- [
          {"event_id", "no"},
          {"request_id", "  "},
          {"model", <<255>>},
          {"input_tokens", 1.0},
          {"booking_version", 0},
          {"complete", nil},
          {"authority", "unknown"},
          {"quoted_cost_microdollars", nil},
          {"observed_at", "2026-09-29T10:00:00+01:00"}
        ] do
      assert {:error, %{code: :invalid_event}} =
               Event.new(Map.put(row, key, value), source())
    end

    assert {:error, %{code: :invalid_source}} =
             Source.new(%{source_id: "https://issuer/token", api_version: 2})

    assert {:error, %{code: :unsupported_kind}} =
             Event.new(Map.put(row, "kind", "routing"), source())

    assert {:error, %{code: :invalid_event}} =
             Event.new(
               Map.merge(row, %{
                 "input_token_basis" => "inclusive",
                 "cache_read_input_tokens" => 1,
                 "cache_creation_input_tokens" => nil
               }),
               source()
             )
  end

  test "schema versions reject numeric coercion and nulls without raising" do
    for version <- [2.0, nil, "2", 3] do
      assert {:error, %{code: :unsupported_version}} =
               Event.new(Map.put(hd(rows()), "schema_version", version), source())
    end
  end

  test "lifecycle charge state requires matching lifecycle authority" do
    assert {:error, %{code: :invalid_event}} =
             Event.new(Map.put(hd(rows()), "charge_state", "lifecycle_only"), source())
  end

  test "producer provisional and witnessed no-work snapshots preserve public facts without private evidence" do
    wire = "test/support/accounting/producer_invariants.json" |> File.read!() |> Jason.decode!()

    for name <-
          ~w(producer_provisional_initial.json producer_corrections.json producer_no_work.json) do
      captured = Path.join("test/support/accounting", name) |> File.read!() |> Jason.decode!()
      for row <- captured["rows"], do: assert({:ok, _} = Event.new(row, source()))
    end

    [initial, _, _, no_work] = wire["rows"]
    for row <- wire["rows"], do: assert({:ok, _} = Event.new(row, source()))

    assert {:ok,
            %{
              charge_state: :provisional,
              booked_total_microdollars: 100,
              quoted_cost_microdollars: nil,
              complete: false,
              authority: :unknown,
              input_tokens: nil,
              model: nil
            }} = Event.new(initial, source())

    assert {:ok,
            %{
              authority: :no_provider_work,
              priceability: :not_applicable,
              charge_state: :settled,
              booked_total_microdollars: 0,
              quoted_cost_microdollars: nil,
              model: nil,
              complete: true,
              input_tokens: 0,
              output_tokens: 0,
              cache_read_input_tokens: 0,
              cache_creation_input_tokens: 0
            }} = Event.new(no_work, source())

    for {field, value} <- [
          {"input_tokens", nil},
          {"output_tokens", 1},
          {"complete", false},
          {"in_flight", "unknown"},
          {"input_token_basis", "inclusive"},
          {"booked_total_microdollars", 1},
          {"charge_state", "provisional"},
          {"quoted_cost_microdollars", 0}
        ] do
      assert {:error, %{code: :invalid_event}} =
               Event.new(Map.put(no_work, field, value), source())
    end
  end
end
