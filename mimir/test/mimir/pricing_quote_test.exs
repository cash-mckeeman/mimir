defmodule Mimir.PricingQuoteTest do
  use ExUnit.Case, async: false

  alias Mimir.Pricing
  alias Mimir.Pricing.{Input, Quote}

  @fixture_path Path.expand("../support/fixtures/pricing_sample.json", __DIR__)
  @model "provider:quote-example"
  @rates %{input: 1_000_000, output: 2_000_000, cache_read: 3_000_000, cache_write: 4_000_000}

  setup do
    previous = Application.get_all_env(:mimir)
    cache_key = {Pricing, :pricing_db, @fixture_path}
    previous_cache = :persistent_term.get(cache_key, :missing)
    :persistent_term.erase(cache_key)
    Application.put_env(:mimir, :pricing_db_path, @fixture_path)
    Application.delete_env(:mimir, :pricing)

    on_exit(fn ->
      for key <- [:pricing, :pricing_db_path] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:mimir, key, value)
          :error -> Application.delete_env(:mimir, key)
        end
      end

      case previous_cache do
        :missing -> :persistent_term.erase(cache_key)
        value -> :persistent_term.put(cache_key, value)
      end
    end)

    :ok
  end

  test "inclusive input subtracts both cache categories exactly once" do
    configure(@rates)
    inclusive = input(%{input_token_basis: :inclusive})
    uncached = input()

    assert {:ok, %Quote{status: :priced, cost_microdollars: 34, input: ^inclusive}} =
             Pricing.quote(@model, inclusive)

    assert {:ok, %Quote{status: :priced, cost_microdollars: 39, input: ^uncached}} =
             Pricing.quote(@model, uncached)
  end

  test "missing measurements and blockers retain facts and take precedence over unavailable rates" do
    configure(@rates)

    incomplete_attrs =
      for field <- [
            :input_tokens,
            :output_tokens,
            :cache_read_input_tokens,
            :cache_creation_input_tokens
          ],
          attrs <- [Map.delete(attributes(), field), Map.put(attributes(), field, nil)],
          do: attrs

    incomplete_attrs =
      incomplete_attrs ++
        [
          attributes(%{input_token_basis: :unknown}),
          attributes(%{complete?: false}),
          attributes(%{in_flight: :unknown})
        ]

    for attrs <- incomplete_attrs, model <- [@model, "unknown:model"] do
      assert {:ok, measurement} = Input.new(attrs)

      assert {:ok,
              %Quote{
                model: ^model,
                input: ^measurement,
                status: :incomplete,
                cost_microdollars: nil
              }} = Pricing.quote(model, measurement)
    end
  end

  test "unknown model remains unpriced even for measured zero usage" do
    for measurement <- [input(), input(zero_counts())] do
      assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
               Pricing.quote("unknown:model", measurement)
    end
  end

  test "each base rate is required even when its measured count is zero" do
    for missing <- [:input, :output] do
      configure(Map.delete(@rates, missing))

      assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
               Pricing.quote(@model, input(zero_counts()))
    end
  end

  test "each positive cache count requires its own available rate" do
    for missing <- [:cache_read, :cache_write] do
      configure(Map.delete(@rates, missing))

      assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
               Pricing.quote(@model, input())
    end
  end

  test "observed zero cache counts require no cache rates" do
    configure(%{input: 1_000_000, output: 2_000_000})

    assert {:ok, %Quote{status: :priced, cost_microdollars: 22}} =
             Pricing.quote(
               @model,
               input(%{cache_read_input_tokens: 0, cache_creation_input_tokens: 0})
             )
  end

  test "missing cache counts remain incomplete when observed zero would be priced" do
    configure(%{input: 1_000_000, output: 2_000_000})

    for field <- [:cache_read_input_tokens, :cache_creation_input_tokens] do
      measurement = input(Map.put(zero_counts(), field, nil))

      assert {:ok, %Quote{status: :incomplete, cost_microdollars: nil, input: ^measurement}} =
               Pricing.quote(@model, measurement)
    end
  end

  test "vendored lookup tries bare database keys then provider-prefixed database keys" do
    measurement =
      input(%{input_tokens: 1_000_000, output_tokens: 500_000} |> Map.merge(no_cache()))

    assert {:ok, %Quote{status: :priced, cost_microdollars: 10_500_000}} =
             Pricing.quote("provider:sample-model-a", measurement)

    assert {:ok, %Quote{status: :priced, cost_microdollars: 2_000_000}} =
             Pricing.quote("anthropic:sample-model-b", measurement)

    assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
             Pricing.quote("prefix:sample-model-c", measurement)
  end

  test "bare model IDs use explicit configuration and preserve the model verbatim" do
    measurement = input(no_cache())

    assert {:ok, %Quote{status: :unpriced}} = Pricing.quote("sample-model-a", measurement)

    Application.put_env(:mimir, :pricing, %{
      "sample-model-a" => %{input: 1_000_000, output: 2_000_000}
    })

    assert {:ok, %Quote{model: "sample-model-a", status: :priced, cost_microdollars: 22}} =
             Pricing.quote("sample-model-a", measurement)
  end

  test "configuration overrides each field while omitted fields retain vendored rates" do
    Application.put_env(:mimir, :pricing, %{
      "provider:sample-model-e" => %{input: 1_000_000, cache_read: 100_000}
    })

    assert {:ok, %Quote{status: :priced, cost_microdollars: 19_850_000}} =
             Pricing.quote("provider:sample-model-e", input(million_counts()))
  end

  test "configured zero overrides a nonzero vendored rate" do
    Application.put_env(:mimir, :pricing, %{
      "provider:sample-model-e" => %{input: 0, cache_read: 0}
    })

    assert {:ok, %Quote{status: :priced, cost_microdollars: 18_750_000}} =
             Pricing.quote("provider:sample-model-e", input(million_counts()))
  end

  test "all explicitly configured zero rates yield priced zero" do
    configure(%{input: 0, output: 0, cache_read: 0, cache_write: 0})

    for measurement <- [input(), input(zero_counts())] do
      assert {:ok, %Quote{status: :priced, cost_microdollars: 0}} =
               Pricing.quote(@model, measurement)
    end
  end

  test "vendored cache zero is absent while a positive vendored cache rate is available" do
    assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
             Pricing.quote("provider:sample-model-g", input())

    assert {:ok, %Quote{status: :priced, cost_microdollars: 65}} =
             Pricing.quote("provider:sample-model-f", input(%{cache_creation_input_tokens: 0}))

    assert {:ok, %Quote{status: :priced, cost_microdollars: 32}} =
             Pricing.quote("provider:sample-model-g", input(no_cache()))
  end

  test "fractional charges truncate each term before summing" do
    configure(%{input: 600_000, output: 600_000, cache_read: 600_000, cache_write: 600_000})

    measurement =
      input(%{
        input_tokens: 3,
        output_tokens: 3,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 3
      })

    assert {:ok, %Quote{status: :priced, cost_microdollars: 4}} =
             Pricing.quote(@model, measurement)
  end

  test "invalid models and non-Input arguments return closed structural errors" do
    for model <- [nil, :model, 123, ""] do
      assert {:error, {:invalid_pricing_model, :invalid_value}} = Pricing.quote(model, input())
    end

    for measurement <- [nil, %{}, attributes(), [], "input"] do
      assert {:error, {:invalid_pricing_input, :not_an_input}} =
               Pricing.quote(@model, measurement)
    end
  end

  test "forged Inputs are revalidated before eligibility classification" do
    for {measurement, reason} <- [
          {%{input() | input_tokens: -1}, {:field, :input_tokens}},
          {%{input() | in_flight: :invalid}, {:field, :in_flight}},
          {%{input() | input_token_basis: :inclusive, input_tokens: 4}, :invalid_cache_partition},
          {Map.put(input(), :extra, 1), :unknown_key},
          {Map.delete(input(), :output_tokens), {:field, :output_tokens}}
        ] do
      assert {:error, {:invalid_pricing_input, ^reason}} = Pricing.quote(@model, measurement)
    end
  end

  test "malformed configuration shapes return tagged errors even for incomplete input" do
    for table <- [
          nil,
          [],
          "rates",
          %URI{},
          %{@model => nil},
          %{@model => []},
          %{@model => 7},
          %{@model => %URI{}}
        ],
        measurement <- [input(), input(%{input_tokens: nil})] do
      Application.put_env(:mimir, :pricing, table)

      assert {:error, {:invalid_pricing_config, message}} = Pricing.quote(@model, measurement)
      assert is_binary(message)
      assert message =~ "Mimir.Pricing"
    end
  end

  test "invalid rates and keys return the dedicated legacy exception message" do
    for rates <- [
          %{input: -1},
          %{output: 1.5},
          %{cache_read: nil},
          %{surprise: 3},
          %{"input" => 1}
        ] do
      configure(rates)

      error =
        assert_raise Pricing.InvalidConfigError, fn -> Pricing.cost_microdollars(@model, %{}) end

      for measurement <- [input(), input(%{input_tokens: nil})] do
        assert {:error, {:invalid_pricing_config, message}} = Pricing.quote(@model, measurement)
        assert message == error.message
      end
    end
  end

  test "quote leaves legacy cache fallback and telemetry intact" do
    configure(%{input: 1_000_000, output: 2_000_000})
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:mimir, :pricing, :no_cache_rate],
        &__MODULE__.forward_no_cache_rate/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %Quote{status: :unpriced, cost_microdollars: nil}} =
             Pricing.quote(@model, input())

    assert {:ok, %Quote{status: :incomplete, cost_microdollars: nil}} =
             Pricing.quote(@model, input(%{complete?: false}))

    refute_received {:no_cache_rate, _, _}

    assert Pricing.cost_microdollars(@model, Map.from_struct(input())) == 27

    assert_received {:no_cache_rate,
                     %{cache_read_input_tokens: 3, cache_creation_input_tokens: 2},
                     %{model: @model}}
  end

  test "legacy non-map configured entries keep their existing vendored fallback" do
    Application.put_env(:mimir, :pricing, %{"provider:sample-model-a" => nil})
    assert Pricing.cost_microdollars("provider:sample-model-a", %{input_tokens: 1}) == 3
  end

  def forward_no_cache_rate(_event, measurements, metadata, test_pid),
    do: send(test_pid, {:no_cache_rate, measurements, metadata})

  defp configure(rates), do: Application.put_env(:mimir, :pricing, %{@model => rates})

  defp attributes(overrides \\ %{}) do
    Map.merge(
      %{
        input_tokens: 12,
        output_tokens: 5,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 2,
        input_token_basis: :uncached,
        complete?: true,
        in_flight: :none
      },
      overrides
    )
  end

  defp input(overrides \\ %{}) do
    {:ok, input} = Input.new(attributes(overrides))
    input
  end

  defp no_cache, do: %{cache_read_input_tokens: 0, cache_creation_input_tokens: 0}

  defp zero_counts,
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }

  defp million_counts,
    do: %{
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000
    }
end
