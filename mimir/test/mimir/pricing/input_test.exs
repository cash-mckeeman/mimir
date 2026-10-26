defmodule Mimir.Pricing.InputTest do
  use ExUnit.Case, async: true

  alias Mimir.Pricing.Input

  @counts [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens]
  @flags [:input_token_basis, :complete?, :in_flight]

  defp attrs do
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

  test "omitted facts stay unknown and explicit count nil is accepted" do
    assert {:ok, input} = Input.new(%{})

    assert Map.from_struct(input) == %{
             input_tokens: nil,
             output_tokens: nil,
             cache_read_input_tokens: nil,
             cache_creation_input_tokens: nil,
             input_token_basis: :unknown,
             complete?: false,
             in_flight: :unknown
           }

    refute Input.priceable?(input)

    for field <- @counts do
      assert {:ok, input} = Input.new(Map.put(attrs(), field, nil))
      assert Map.fetch!(input, field) == nil
      refute Input.priceable?(input)
    end
  end

  test "missing cache counts remain unknown while observed zero is priceable" do
    attrs = %{attrs() | input_token_basis: :uncached}
    assert {:ok, missing} = Input.new(Map.delete(attrs, :cache_read_input_tokens))
    assert missing.cache_read_input_tokens == nil
    refute Input.priceable?(missing)
    assert {:ok, zero} = Input.new(Map.put(attrs, :cache_read_input_tokens, 0))
    assert zero.cache_read_input_tokens == 0
    assert Input.priceable?(zero)
  end

  test "retains measurements and validates inclusive cache partitions" do
    assert {:ok, input} = Input.new(attrs())
    assert Map.from_struct(input) == attrs()
    assert Input.priceable?(input)
    assert {:ok, ^input} = Input.new(input)

    assert {:error, {:invalid_pricing_input, :invalid_cache_partition}} =
             Input.new(%{attrs() | input_tokens: 4})

    assert {:ok, incomplete} = Input.new(%{attrs() | input_tokens: nil})
    assert incomplete.input_tokens == nil
    refute Input.priceable?(incomplete)

    for field <- [:cache_read_input_tokens, :cache_creation_input_tokens] do
      assert {:ok, incomplete} = Input.new(Map.put(%{attrs() | input_tokens: 4}, field, nil))
      assert Map.fetch!(incomplete, field) == nil
      refute Input.priceable?(incomplete)
    end

    assert {:ok, unknown_input} =
             Input.new(%{attrs() | input_tokens: nil, cache_creation_input_tokens: nil})

    assert unknown_input.input_tokens == nil
    assert unknown_input.cache_read_input_tokens == 3
    assert unknown_input.cache_creation_input_tokens == nil
    refute Input.priceable?(unknown_input)

    assert {:ok, uncached} = Input.new(%{attrs() | input_tokens: 1, input_token_basis: :uncached})
    assert uncached.input_tokens == 1
    assert Input.priceable?(uncached)
    assert {:ok, _} = Input.new(%{attrs() | input_tokens: 5})
  end

  test "rejects known cache reads exceeding inclusive input when cache writes are unknown" do
    assert {:error, {:invalid_pricing_input, :invalid_cache_partition}} =
             Input.new(%{
               attrs()
               | input_tokens: 4,
                 cache_read_input_tokens: 5,
                 cache_creation_input_tokens: nil
             })
  end

  test "rejects known cache writes exceeding inclusive input when cache reads are unknown" do
    assert {:error, {:invalid_pricing_input, :invalid_cache_partition}} =
             Input.new(%{
               attrs()
               | input_tokens: 4,
                 cache_read_input_tokens: nil,
                 cache_creation_input_tokens: 5
             })
  end

  test "each missing count or blocked measurement prevents priceability" do
    for field <- @counts do
      assert {:ok, input} = Input.new(Map.delete(attrs(), field))
      refute Input.priceable?(input)
    end

    for {field, value} <- [input_token_basis: :unknown, complete?: false, in_flight: :unknown] do
      assert {:ok, input} = Input.new(Map.put(attrs(), field, value))
      refute Input.priceable?(input)
    end

    zeroes = Map.merge(attrs(), Map.new(@counts, &{&1, 0}))
    assert {:ok, input} = Input.new(zeroes)
    assert Input.priceable?(input)
  end

  test "rejects malformed count fields without coercion" do
    for field <- @counts, value <- [-1, 1.5, "0", false, [], %{}] do
      assert {:error, {:invalid_pricing_input, {:field, ^field}}} =
               Input.new(Map.put(attrs(), field, value))
    end
  end

  test "rejects malformed flags including explicit nil" do
    for {field, values} <- [
          input_token_basis: [nil, :other, "inclusive", 0],
          complete?: [nil, :unknown, "true", 1],
          in_flight: [nil, :other, "none", false]
        ],
        value <- values do
      assert {:error, {:invalid_pricing_input, {:field, ^field}}} =
               Input.new(Map.put(attrs(), field, value))
    end
  end

  test "rejects unknown keys and non-map containers" do
    for key <- [:extra, "input_tokens", "extra", 1, :__struct__] do
      assert {:error, {:invalid_pricing_input, :unknown_key}} =
               Input.new(Map.put(attrs(), key, :unexpected))
    end

    for value <- [nil, false, 0, "input", [], [input_tokens: 1], {:input, 1}] do
      assert {:error, {:invalid_pricing_input, :not_a_map}} = Input.new(value)
    end

    assert {:error, {:invalid_pricing_input, :unknown_key}} = Input.new(%URI{})
  end

  test "revalidates forged structs rather than trusting their tag" do
    assert {:ok, input} = Input.new(attrs())

    for field <- @counts ++ @flags do
      assert {:error, {:invalid_pricing_input, {:field, ^field}}} =
               Input.new(Map.put(input, field, :invalid))

      assert {:error, {:invalid_pricing_input, {:field, ^field}}} =
               Input.new(Map.delete(input, field))
    end

    assert {:error, {:invalid_pricing_input, :unknown_key}} =
             Input.new(Map.put(input, :extra, 1))

    assert {:error, {:invalid_pricing_input, :invalid_cache_partition}} =
             Input.new(%{input | input_tokens: 4})
  end
end
