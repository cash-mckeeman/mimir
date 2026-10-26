defmodule Mimir.Pricing.QuoteTest do
  use ExUnit.Case, async: true

  alias Mimir.Pricing.Input
  alias Mimir.Pricing.Quote

  @counts [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens]

  defp input_attrs do
    %{
      input_tokens: 12,
      output_tokens: 5,
      cache_read_input_tokens: 3,
      cache_creation_input_tokens: 2,
      input_token_basis: :inclusive,
      complete?: true,
      in_flight: :none
    }
  end

  defp attrs(input, status, cost) do
    %{model: "quote-example", input: input, status: status, cost_microdollars: cost}
  end

  test "accepts priced zero and unpriced nil while retaining model and input" do
    assert {:ok, input} = Input.new(input_attrs())

    assert {:ok, quote} = Quote.new(attrs(input, :priced, 0))
    assert Map.from_struct(quote) == attrs(input, :priced, 0)
    assert {:ok, ^quote} = Quote.new(quote)

    assert {:ok, unpriced} = Quote.new(attrs(input, :unpriced, nil))
    assert unpriced.input == input
    assert unpriced.status == :unpriced
    assert unpriced.cost_microdollars == nil

    assert {:ok, positive} = Quote.new(attrs(input_attrs(), :priced, 42))
    assert positive.input == input
    assert positive.cost_microdollars == 42
    assert {:ok, spaced} = Quote.new(%{attrs(input, :priced, 0) | model: " model "})
    assert spaced.model == " model "
  end

  test "incomplete status requires a missing measurement fact or blocker" do
    blockers =
      Enum.map(@counts, &{&1, nil}) ++
        [input_token_basis: :unknown, complete?: false, in_flight: :unknown]

    for {field, value} <- blockers do
      assert {:ok, input} = Input.new(Map.put(input_attrs(), field, value))
      assert {:ok, incomplete} = Quote.new(attrs(input, :incomplete, nil))
      assert incomplete.input == input
      assert incomplete.status == :incomplete
      assert incomplete.cost_microdollars == nil

      for status <- [:priced, :unpriced] do
        cost = if status == :priced, do: 0

        assert {:error, {:invalid_pricing_quote, {:field, :status}}} =
                 Quote.new(attrs(input, status, cost))
      end
    end

    assert {:error, {:invalid_pricing_quote, {:field, :status}}} =
             Quote.new(attrs(input_attrs(), :incomplete, nil))
  end

  test "requires a nonnegative integer cost only for priced status" do
    for cost <- [nil, -1, 1.5, "0", false] do
      assert {:error, {:invalid_pricing_quote, {:field, :cost_microdollars}}} =
               Quote.new(attrs(input_attrs(), :priced, cost))
    end

    assert {:error, {:invalid_pricing_quote, {:field, :cost_microdollars}}} =
             Quote.new(Map.delete(attrs(input_attrs(), :priced, 0), :cost_microdollars))

    for status <- [:unpriced, :incomplete], cost <- [0, 1, -1, 1.5, "0"] do
      input = if status == :incomplete, do: %{}, else: input_attrs()

      assert {:error, {:invalid_pricing_quote, {:field, :cost_microdollars}}} =
               Quote.new(attrs(input, status, cost))
    end
  end

  test "validates model status and input at their field boundaries" do
    for model <- [nil, "", :model, 1, [], %{}] do
      assert {:error, {:invalid_pricing_quote, {:field, :model}}} =
               Quote.new(%{attrs(input_attrs(), :priced, 0) | model: model})
    end

    for status <- [nil, :other, "priced", 1] do
      assert {:error, {:invalid_pricing_quote, {:field, :status}}} =
               Quote.new(attrs(input_attrs(), status, 0))
    end

    for input <- [nil, [], "input", 1, %URI{}, %{input_tokens: -1}, %{extra: 1}] do
      assert {:error, {:invalid_pricing_quote, {:field, :input}}} =
               Quote.new(attrs(input, :priced, 0))
    end

    assert {:error, {:invalid_pricing_quote, {:field, :input}}} =
             Quote.new(attrs(%{input_attrs() | input_tokens: 4}, :priced, 0))
  end

  test "rejects missing fields unknown keys and wrong containers" do
    for field <- [:model, :input, :status, :cost_microdollars] do
      assert {:error, {:invalid_pricing_quote, {:field, ^field}}} =
               Quote.new(Map.delete(attrs(input_attrs(), :priced, 0), field))
    end

    for key <- [:extra, "model", "extra", 1, :__struct__] do
      assert {:error, {:invalid_pricing_quote, :unknown_key}} =
               Quote.new(Map.put(attrs(input_attrs(), :priced, 0), key, :unexpected))
    end

    for value <- [nil, false, 0, "quote", [], [model: "model"], {:quote, 1}] do
      assert {:error, {:invalid_pricing_quote, :not_a_map}} = Quote.new(value)
    end

    assert {:error, {:invalid_pricing_quote, :unknown_key}} = Quote.new(%URI{})
  end

  test "revalidates forged quote and nested input structs" do
    assert {:ok, input} = Input.new(input_attrs())
    assert {:ok, quote} = Quote.new(attrs(input, :priced, 0))

    for field <- [:model, :input, :status, :cost_microdollars] do
      assert {:error, {:invalid_pricing_quote, {:field, ^field}}} =
               Quote.new(Map.put(quote, field, :invalid))

      assert {:error, {:invalid_pricing_quote, {:field, ^field}}} =
               Quote.new(Map.delete(quote, field))
    end

    assert {:error, {:invalid_pricing_quote, :unknown_key}} =
             Quote.new(Map.put(quote, :extra, 1))

    for field <- @counts ++ [:input_token_basis, :complete?, :in_flight] do
      for forged <- [Map.put(input, field, :invalid), Map.delete(input, field)] do
        assert {:error, {:invalid_pricing_quote, {:field, :input}}} =
                 Quote.new(%{quote | input: forged})
      end
    end

    for forged <- [Map.put(input, :extra, 1), %{input | input_tokens: 4}] do
      assert {:error, {:invalid_pricing_quote, {:field, :input}}} =
               Quote.new(%{quote | input: forged})
    end
  end
end
