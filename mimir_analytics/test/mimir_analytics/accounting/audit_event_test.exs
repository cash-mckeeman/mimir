defmodule MimirAnalytics.Accounting.AuditEventTest do
  use ExUnit.Case, async: true
  alias MimirAnalytics.Accounting.{AuditEvent, Event, ExportEvent, Page, Source}

  defp source(id \\ "test:audit") do
    {:ok, source} = Source.new(%{source_id: id, api_version: 2})
    source
  end

  defp rows do
    "test/support/accounting/audits/audit-only.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("rows")
  end

  test "captured variants retain exact typed facts without invented financial fields" do
    common =
      ~w(schema_version event_id kind virtual_key_id run_id request_id recorded_at observed_at workflow_id step_id parent_step_id facts)

    assert Enum.map(rows(), & &1["facts"]["outcome"]) ==
             ~w(placed grant_failed no_candidate ok error unknown)

    for row <- rows() do
      assert Enum.sort(Map.keys(row)) == Enum.sort(common)

      facts =
        if row["kind"] == "routing",
          do: ~w(decision_id outcome selected_model selected_lane grant_id),
          else: ~w(phase outcome session_id turn_id)

      assert Enum.sort(Map.keys(row["facts"])) == Enum.sort(facts)
      assert {:ok, event} = AuditEvent.new(row, source())
      assert {:ok, ^event} = ExportEvent.new(row, source())
      assert is_struct(event.facts)
      refute Map.has_key?(event, :booking_version)
      assert Enum.sort(Map.keys(ExportEvent.to_wire(event))) == Enum.sort(common)
      assert {:error, %{code: :unsupported_kind}} = Event.new(row, source())

      ref =
        if row["kind"] == "routing",
          do: "routing:" <> row["facts"]["decision_id"],
          else: "lifecycle:" <> row["run_id"] <> ":run_returned"

      assert AuditEvent.source_ref(event) == ref
      assert event.run_id == row["run_id"]
    end
  end

  test "normalizes canonical spelling and fingerprints every audit fact and source" do
    for row <- rows() do
      assert {:ok, event} = AuditEvent.new(row, source())

      canonical =
        row
        |> Map.put("event_id", String.upcase(row["event_id"]))
        |> Map.put("observed_at", "2026-10-26T16:12:31.000000+00:00")

      assert {:ok, ^event} = AuditEvent.new(canonical, source())
      assert {:ok, other_source} = AuditEvent.new(row, source("other:audit"))
      refute AuditEvent.fingerprint(event) == AuditEvent.fingerprint(other_source)

      for field <- ~w(request_id workflow_id step_id parent_step_id observed_at recorded_at) do
        value =
          if field in ~w(observed_at recorded_at), do: "2026-10-27T16:12:31Z", else: "different"

        assert {:ok, changed} = AuditEvent.new(Map.put(row, field, value), source())
        refute AuditEvent.fingerprint(event) == AuditEvent.fingerprint(changed)
      end

      for field <-
            ~w(event_id virtual_key_id) ++
              if(row["kind"] == "lifecycle", do: ["run_id"], else: []) do
        assert {:ok, changed} =
                 AuditEvent.new(
                   Map.put(row, field, "00000000-0000-4000-8000-000000000001"),
                   source()
                 )

        refute AuditEvent.fingerprint(event) == AuditEvent.fingerprint(changed)

        assert {:ok, ^event} =
                 AuditEvent.new(Map.put(row, field, String.upcase(row[field])), source())
      end

      assert ExportEvent.fingerprint(event) == AuditEvent.fingerprint(event)
    end

    [row | _] = rows()
    assert {:ok, event} = AuditEvent.new(row, source())

    for {field, value} <- [
          {"decision_id", "rd_aaaaaaaaaaaaaaaaaaaaaaaaaa"},
          {"selected_model", "another"},
          {"selected_lane", "remote"},
          {"grant_id", row["event_id"]}
        ] do
      assert {:ok, changed} = AuditEvent.new(put_in(row, ["facts", field], value), source())
      refute AuditEvent.fingerprint(event) == AuditEvent.fingerprint(changed)
    end

    life = Enum.at(rows(), 3)
    {:ok, original} = AuditEvent.new(life, source())

    for {field, value} <- [
          {"outcome", "error"},
          {"session_id", "different"},
          {"turn_id", "different"}
        ] do
      {:ok, changed} = AuditEvent.new(put_in(life, ["facts", field], value), source())
      refute AuditEvent.fingerprint(original) == AuditEvent.fingerprint(changed)
    end
  end

  test "strict audit keys enums identities and facts reject whole pages with safe errors" do
    [route, failed, none, life | _] = rows()

    invalid = [
      Map.delete(route, "workflow_id"),
      Map.put(route, "booking_version", 0),
      Map.put(route, "run_id", life["run_id"]),
      Map.put(life, "run_id", nil),
      Map.put(route, "event_id", "secret-token"),
      Map.put(route, "request_id", " "),
      Map.put(route, "workflow_id", <<255>>),
      Map.put(route, "observed_at", "2026-10-26T16:12:31+01:00"),
      put_in(route, ["facts", "grant_id"], nil),
      put_in(failed, ["facts", "grant_id"], route["facts"]["grant_id"]),
      put_in(none, ["facts", "selected_model"], "secret-token"),
      put_in(route, ["facts", "decision_id"], "rd_BAD"),
      put_in(life, ["facts", "phase"], "terminated"),
      put_in(life, ["facts", "outcome"], "secret-token"),
      put_in(life, ["facts", "session_id"], ""),
      put_in(life, ["facts", "turn_id"], 42),
      put_in(life, ["facts", "error_class"], "secret-token"),
      Map.put(life, "facts", route["facts"]),
      Map.put(route, "facts", nil)
    ]

    for row <- invalid do
      assert {:error, error} = AuditEvent.new(row, source())
      refute inspect(error) =~ "secret-token"

      assert {:error, _} =
               Page.new(
                 %{
                   "api_version" => 2,
                   "rows" => [life, row],
                   "limit" => 500,
                   "next_cursor" => "next"
                 },
                 source(),
                 nil
               )
    end

    for version <- [2.0, nil, "2", 3] do
      assert {:error, %{code: :unsupported_version}} =
               ExportEvent.new(Map.put(route, "schema_version", version), source())
    end

    assert {:error, %{code: :unsupported_kind}} =
             ExportEvent.new(Map.put(route, "kind", "secret-token"), source())

    assert {:error, %{code: :invalid_event}} = ExportEvent.new(:invalid, source())
  end
end
