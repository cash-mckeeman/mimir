defmodule Mimir.PricingTest do
  use ExUnit.Case, async: false
  alias Mimir.Pricing

  @fixture_path Path.expand("../support/fixtures/pricing_sample.json", __DIR__)

  # Erase any persistent_term entries that would be cached from prior test runs.
  # Capture and restore original app-env values so that later tests relying on
  # config-supplied pricing still see it after this file runs.
  setup do
    prev_pricing = Application.get_env(:mimir, :pricing)
    prev_db_path = Application.get_env(:mimir, :pricing_db_path)
    :persistent_term.erase({Mimir.Pricing, :pricing_db, @fixture_path})

    on_exit(fn ->
      :persistent_term.erase({Mimir.Pricing, :pricing_db, @fixture_path})

      if prev_pricing != nil,
        do: Application.put_env(:mimir, :pricing, prev_pricing),
        else: Application.delete_env(:mimir, :pricing)

      if prev_db_path != nil,
        do: Application.put_env(:mimir, :pricing_db_path, prev_db_path),
        else: Application.delete_env(:mimir, :pricing_db_path)
    end)

    Application.delete_env(:mimir, :pricing_db_path)
    Application.delete_env(:mimir, :pricing)
    :ok
  end

  # ── original tests (preserved) ──────────────────────────────────────────────

  test "computes integer microdollar cost from usage" do
    Application.put_env(:mimir, :pricing, %{
      "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
    })

    usage = %{input_tokens: 1_000, output_tokens: 500}
    # 1000 * 3_000_000 / 1_000_000 = 3_000 ; 500 * 15_000_000 / 1_000_000 = 7_500
    assert Pricing.cost_microdollars("anthropic:claude-sonnet-4-6", usage) == 10_500
  end

  test "unknown model prices at zero (never crashes metering)" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    assert Pricing.cost_microdollars("unknown:model", %{input_tokens: 10, output_tokens: 10}) == 0
  end

  test "missing usage fields default to zero tokens" do
    Application.put_env(:mimir, :pricing, %{
      "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
    })

    assert Pricing.cost_microdollars("anthropic:claude-sonnet-4-6", %{}) == 0
  end

  # ── (a) config table wins over vendored DB ───────────────────────────────────

  test "(a) config table entry wins when present, vendored DB not consulted" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    # "sample-model-a" is in the fixture with 3_000_000 µ$/M input,
    # but we set a config override with a clearly different rate.
    Application.put_env(:mimir, :pricing, %{
      "provider:sample-model-a" => %{input: 999_000, output: 888_000}
    })

    usage = %{input_tokens: 1_000_000, output_tokens: 0}
    # Should use config: 1_000_000 * 999_000 / 1_000_000 = 999_000
    assert Pricing.cost_microdollars("provider:sample-model-a", usage) == 999_000
  end

  # ── (b) fallback via bare key and provider/-prefixed key ─────────────────────

  test "(b1) fallback hit via bare model_id when no config entry" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    # fixture: "sample-model-a" input_cost_per_token: 0.000003
    # → round(0.000003 * 1.0e12) = 3_000_000 µ$/M
    # cost_microdollars("provider:sample-model-a", %{input_tokens: 2_000_000, output_tokens: 0})
    # = div(2_000_000 * 3_000_000, 1_000_000) = 6_000_000
    usage = %{input_tokens: 2_000_000, output_tokens: 0}
    assert Pricing.cost_microdollars("provider:sample-model-a", usage) == 6_000_000
  end

  test "(b2) fallback hit via provider/-prefixed key in fixture" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    # fixture key: "anthropic/sample-model-b"
    # input_cost_per_token: 0.0000008 → round(0.0000008 * 1.0e12) = 800_000 µ$/M
    # output_cost_per_token: 0.0000024 → round(0.0000024 * 1.0e12) = 2_400_000 µ$/M
    # cost for input=1_000_000 tokens, output=500_000 tokens:
    # div(1_000_000 * 800_000, 1_000_000) + div(500_000 * 2_400_000, 1_000_000)
    # = 800_000 + 1_200_000 = 2_000_000
    usage = %{input_tokens: 1_000_000, output_tokens: 500_000}
    assert Pricing.cost_microdollars("anthropic:sample-model-b", usage) == 2_000_000
  end

  test "(b3) µ$ conversion: bare key, exact integer arithmetic" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)

    # fixture: "sample-model-d" input: 0.000001 → 1_000_000 µ$/M, output: 0.000005 → 5_000_000 µ$/M
    # cost for 500 input, 200 output:
    # div(500 * 1_000_000, 1_000_000) + div(200 * 5_000_000, 1_000_000) = 500 + 1_000 = 1_500
    usage = %{input_tokens: 500, output_tokens: 200}
    assert Pricing.cost_microdollars("someprefix:sample-model-d", usage) == 1_500
  end

  # ── (c) miss → existing behavior (zero) ─────────────────────────────────────

  test "(c) complete miss in both config and vendored DB returns zero (existing behavior)" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)

    assert Pricing.cost_microdollars("totally:unknown-model-xyz", %{
             input_tokens: 100,
             output_tokens: 100
           }) == 0
  end

  # ── (d) corrupt/missing file → warning + config-only, no crash ───────────────

  test "(d1) missing DB file logs warning and falls back to config-only" do
    missing_path = "/tmp/mimir_pricing_does_not_exist_#{System.unique_integer()}.json"
    :persistent_term.erase({Mimir.Pricing, :pricing_db, missing_path})
    Application.put_env(:mimir, :pricing_db_path, missing_path)

    Application.put_env(:mimir, :pricing, %{
      "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
    })

    # Trigger the DB load (and warning) with a model that is NOT in the config table,
    # so the fallback path is reached and pricing_db/0 loads (and fails) the missing file.
    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        # "not-in-config:model" is absent from the config table → fallback path tries the DB
        _zero =
          Pricing.cost_microdollars("not-in-config:model", %{input_tokens: 1, output_tokens: 0})
      end)

    assert log =~ "pricing"

    # Config table path still resolves correctly (the missing DB is now cached as empty).
    result =
      Pricing.cost_microdollars("anthropic:claude-sonnet-4-6", %{
        input_tokens: 1_000,
        output_tokens: 0
      })

    assert result == 3_000

    on_exit(fn ->
      :persistent_term.erase({Mimir.Pricing, :pricing_db, missing_path})
    end)
  end

  test "(d2) corrupt DB file logs warning and behaves as empty DB" do
    corrupt_path = "/tmp/mimir_pricing_corrupt_#{System.unique_integer()}.json"
    :persistent_term.erase({Mimir.Pricing, :pricing_db, corrupt_path})
    File.write!(corrupt_path, "NOT VALID JSON {{{")
    Application.put_env(:mimir, :pricing_db_path, corrupt_path)

    import ExUnit.CaptureLog
    prev = Logger.level()
    Logger.configure(level: :warning)

    log =
      capture_log([level: :warning], fn ->
        result =
          Pricing.cost_microdollars("sample-model-a", %{input_tokens: 1_000, output_tokens: 0})

        # no config entry, corrupt DB → zero
        assert result == 0
      end)

    Logger.configure(level: prev)
    assert log =~ "pricing"

    on_exit(fn ->
      :persistent_term.erase({Mimir.Pricing, :pricing_db, corrupt_path})
      File.rm(corrupt_path)
    end)
  end

  test "(d3) entry missing output_cost_per_token is skipped" do
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    # "sample-model-c" in fixture has no output_cost_per_token → should be skipped → zero
    assert Pricing.cost_microdollars("prefix:sample-model-c", %{
             input_tokens: 1_000,
             output_tokens: 500
           }) == 0
  end
end
