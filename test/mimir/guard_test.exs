defmodule Mimir.GuardTest do
  use ExUnit.Case, async: false

  # anthropic:claude-sonnet-4-6 in config pricing: input 3_000_000 µ$/Mtok, output 15_000_000 µ$/Mtok
  @model "anthropic:claude-sonnet-4-6"

  setup do
    Application.put_env(:mimir, :pricing, %{
      @model => %{input: 3_000_000, output: 15_000_000}
    })

    on_exit(fn -> Application.delete_env(:mimir, :pricing) end)
  end

  defp state(input, output, turns \\ 1),
    do: %{usage: %{input_tokens: input, output_tokens: output}, turns: turns, session_id: "s1"}

  describe "for_grant/3" do
    test "continues while priced cost is under budget" do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: 50_000}, @model)
      # 1000 in + 1000 out = 3_000 + 15_000 = 18_000 µ$
      assert guard.(state(1_000, 1_000)) == :cont
    end

    test "halts with budget_exceeded at/over budget" do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: 18_000}, @model)

      assert {:halt, {:budget_exceeded, info}} = guard.(state(1_000, 1_000))
      assert info.cost_microdollars == 18_000
      assert info.budget_microdollars == 18_000
      assert info.usage == %{input_tokens: 1_000, output_tokens: 1_000}
    end

    test "accepts string-keyed usage and string-keyed grant" do
      guard = Mimir.Guard.for_grant(%{"budget_microdollars" => 18_000}, @model)

      assert {:halt, {:budget_exceeded, _}} =
               guard.(%{usage: %{"input_tokens" => 1_000, "output_tokens" => 1_000}, turns: 1})
    end

    test "nil or missing budget never halts on cost" do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: nil}, @model)
      assert guard.(state(9_999_999, 9_999_999)) == :cont

      guard = Mimir.Guard.for_grant(%{}, @model)
      assert guard.(state(9_999_999, 9_999_999)) == :cont
    end

    test "pricing miss degrades to :cont and emits telemetry once" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "guard-miss-#{inspect(ref)}",
        [:mimir, :guard, :pricing_miss],
        fn _e, _m, meta, _ -> send(pid, {:miss, meta.model}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("guard-miss-#{inspect(ref)}") end)

      guard = Mimir.Guard.for_grant(%{budget_microdollars: 10}, "unknown:model")

      task =
        Task.async(fn ->
          assert guard.(state(1_000, 1_000)) == :cont
          assert guard.(state(2_000, 2_000)) == :cont
        end)

      Task.await(task)
      assert_receive {:miss, "unknown:model"}
      refute_receive {:miss, "unknown:model"}, 50
    end

    test "grant guard composes with cap opts" do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: 1_000_000}, @model, max_turns: 3)
      assert guard.(state(1, 1, 2)) == :cont
      assert {:halt, {:max_turns, %{turns: 3, max: 3}}} = guard.(state(1, 1, 3))
    end

    test "never raises on non-map or non-integer usage (degrades to :cont)" do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: 18_000}, @model)

      # non-map usage
      assert guard.(%{usage: nil, turns: 1}) == :cont
      # non-integer token values
      assert guard.(%{usage: %{input_tokens: "lots", output_tokens: nil}, turns: 1}) == :cont
    end
  end

  describe "caps/1" do
    test "no options never halts" do
      guard = Mimir.Guard.caps()
      assert guard.(state(1_000_000, 1_000_000, 500)) == :cont
    end

    test "max_total_tokens halts on input+output" do
      guard = Mimir.Guard.caps(max_total_tokens: 1_500)

      assert guard.(state(700, 700)) == :cont

      assert {:halt, {:max_total_tokens, %{total_tokens: 1_600, max: 1_500}}} =
               guard.(state(800, 800))
    end

    test "max_cost_microdollars with model prices like a grant" do
      guard = Mimir.Guard.caps(max_cost_microdollars: 18_000, model: @model)
      assert {:halt, {:budget_exceeded, _}} = guard.(state(1_000, 1_000))
    end
  end
end
