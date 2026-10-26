defmodule MimirAnalytics.AccountingInteropHelper do
  @moduledoc false
  import ExUnit.Assertions
  alias MimirAnalytics.{Store, Views}

  def fixture(name), do: Path.join("test/support/accounting", name <> ".json")
  def body(name), do: name |> fixture() |> File.read!()
  def wire(name), do: name |> body() |> Jason.decode!()

  def respond(conn, name, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body(name))
  end

  # Test repartitioning changes only reader wrappers; rows are producer bytes decoded at ingress.
  def wrapper(dir, rows, name) do
    path = Path.join(dir, name <> ".jsonl")

    File.write!(
      path,
      Jason.encode!(%{
        "kind" => "accounting_page",
        "buffer_version" => 1,
        "source_id" => "test:producer",
        "api_version" => 2,
        "from_cursor" => nil,
        "next_cursor" => "repartition:" <> name,
        "limit" => 500,
        "rows" => rows
      }) <> "\n"
    )

    path
  end

  def accounting_snapshot(store) do
    :ok = Views.apply(store.conn)

    for table <- ~w(accounting_events accounting_states v_gateway_accounting_spend), into: %{} do
      {:ok, rows} = Store.query(store, "SELECT * FROM #{table} ORDER BY ALL")
      {table, rows}
    end
  end

  def assert_main_facts(store) do
    assert {:ok, [[5]]} = Store.query(store, "SELECT count(*) FROM accounting_events")
    assert {:ok, [[3]]} = Store.query(store, "SELECT count(*) FROM accounting_states")

    assert {:ok, [[1, 7, 100, 100], [2, 9, 80, -20], [3, 13, 70, -10]]} =
             Store.query(store, """
             SELECT booking_version, CAST(event_json->>'measurement_version' AS BIGINT),
                    CAST(event_json->>'booked_total_microdollars' AS BIGINT),
                    CAST(event_json->>'delta_microdollars' AS BIGINT)
             FROM accounting_events WHERE run_id = 'ff9d74b9-97c3-4ada-9cd5-f43a61478456'
             ORDER BY booking_version
             """)

    assert {:ok,
            [
              [
                true,
                nil,
                4,
                0,
                nil,
                nil,
                nil,
                "inclusive",
                "unknown",
                "http",
                "incomplete",
                "unreconciled"
              ]
            ]} =
             Store.query(store, """
             SELECT CAST(event_json->>'complete' AS BOOLEAN),
                    CAST(event_json->>'input_tokens' AS BIGINT),
                    CAST(event_json->>'output_tokens' AS BIGINT),
                    CAST(event_json->>'cache_read_input_tokens' AS BIGINT),
                    CAST(event_json->>'cache_creation_input_tokens' AS BIGINT),
                    event_json->>'model', CAST(event_json->>'quoted_cost_microdollars' AS BIGINT),
                    event_json->>'input_token_basis', event_json->>'in_flight',
                    event_json->>'measurement_owner', event_json->>'priceability',
                    event_json->>'charge_state'
             FROM accounting_events WHERE run_id = '6a3d944f-17cd-43c6-97a9-7b6d594d0ce9'
             """)

    :ok = Views.apply(store.conn)
    assert {:ok, [[70, 0, 0, 0, 0]]} = spend(store, "2dbe5c79-85f7-4988-a649-d8ebce0da44d")
    assert {:ok, [[0, 0, 0, 0, 0]]} = spend(store, "fc8339b0-43ed-40ff-913f-9aa8be023cbd")
    assert {:ok, [[0, 0, 0, 1, 1]]} = spend(store, "8f778a4e-b4b1-4d04-9c73-16c24223300c")

    assert {:ok, [[0, 0, 0, 0, 0, "wire"]]} =
             Store.query(store, """
             SELECT CAST(event_json->>'input_tokens' AS BIGINT),
                    CAST(event_json->>'output_tokens' AS BIGINT),
                    CAST(event_json->>'cache_read_input_tokens' AS BIGINT),
                    CAST(event_json->>'cache_creation_input_tokens' AS BIGINT),
                    CAST(event_json->>'quoted_cost_microdollars' AS BIGINT),
                    event_json->>'measurement_owner'
             FROM accounting_events WHERE run_id = '43c04c55-6024-45c7-9111-0301a8ce7c66'
             """)
  end

  def spend(store, key) do
    Store.query(
      store,
      """
      SELECT booked_applied_total_microdollars, missing_history_runs, provisional_runs,
             unreconciled_runs, unknown_price_runs FROM v_gateway_accounting_spend
      WHERE virtual_key_id = ? AND budget_period_start = DATE '2026-09-01'
      """,
      [key]
    )
  end
end
