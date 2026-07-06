defmodule Mimir.Guard do
  @moduledoc """
  Turn-guard builders for a session loop's between-turn hook (RMA 0.5.0's
  `turn_guard:` option). Plain data in, plain verdict out — no RMA types.

  `for_grant/3` prices the session's accumulated usage with `Mimir.Pricing`
  and halts once the grant budget is spent — the control-plane soft half of
  enforcement, for runtimes where the gateway cannot sit in the data plane.
  `caps/1` is the mimir-less form: plain cost/token/turn caps, no minted key.

  Guards never raise mid-run: on a pricing-table miss the cost check degrades
  to whatever caps remain and a `[:mimir, :guard, :pricing_miss]` telemetry
  warning is emitted (once per process per model).
  """

  @type turn_state :: %{
          required(:usage) => map(),
          required(:turns) => non_neg_integer(),
          optional(any()) => any()
        }
  @type verdict :: :cont | {:halt, term()}
  @type guard_fun :: (turn_state() -> verdict())

  @doc """
  Build a guard from a route-response grant. Pass `resp.grant` from a
  `%Mimir.RouteResponse{}`. A `%Grant{}` with a nil `budget_microdollars`
  never halts on cost. `opts` take `caps/1` options; caps are checked before
  the budget.
  """
  @spec for_grant(Mimir.Grant.t(), String.t(), keyword()) :: guard_fun()
  def for_grant(%Mimir.Grant{} = grant, model, opts \\ []) when is_binary(model) do
    budget = grant.budget_microdollars
    caps_fun = caps(opts)

    fn state ->
      with :cont <- caps_fun.(state) do
        check_budget(state, model, budget)
      end
    end
  end

  @doc """
  Build a guard from plain caps — the mimir-less form. Options:

  - `:max_turns` — halt once `turns` reaches the cap
  - `:max_total_tokens` — halt once input+output tokens reach the cap
  - `:max_cost_microdollars` (with `:model`) — priced cost cap

  Omitted caps don't constrain; with no options the guard always continues.
  """
  @spec caps(keyword()) :: guard_fun()
  def caps(opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns)
    max_tokens = Keyword.get(opts, :max_total_tokens)
    max_cost = Keyword.get(opts, :max_cost_microdollars)
    model = Keyword.get(opts, :model)

    fn state ->
      usage = normalize_usage(state.usage)
      total = usage.input_tokens + usage.output_tokens

      cond do
        is_integer(max_turns) and state.turns >= max_turns ->
          {:halt, {:max_turns, %{turns: state.turns, max: max_turns}}}

        is_integer(max_tokens) and total >= max_tokens ->
          {:halt, {:max_total_tokens, %{total_tokens: total, max: max_tokens}}}

        is_integer(max_cost) and is_binary(model) ->
          check_budget(state, model, max_cost)

        true ->
          :cont
      end
    end
  end

  defp check_budget(_state, _model, budget) when not is_integer(budget), do: :cont

  defp check_budget(state, model, budget) do
    usage = normalize_usage(state.usage)
    cost = Mimir.Pricing.cost_microdollars(model, usage)

    cond do
      cost == 0 and usage.input_tokens + usage.output_tokens > 0 ->
        maybe_warn_pricing_miss(model, usage)
        :cont

      cost >= budget ->
        {:halt,
         {:budget_exceeded, %{cost_microdollars: cost, budget_microdollars: budget, usage: usage}}}

      true ->
        :cont
    end
  end

  # RMA 0.5.0 hands turn_guard a %ReqManagedAgents.Usage{} STRUCT, not a plain map — so
  # read with Map.get, never bracket access. `usage[:k]` / `usage["k"]` raise on a struct
  # (no Access behaviour), which would violate "never raises mid-run". Map.get reads a
  # struct AND a plain atom- or string-keyed map, so injected / mimir-less callers work.
  # A non-map usage, or a non-integer token value, degrades to 0 rather than raising, so
  # the "never raises mid-run" guarantee holds for any caller — not only contract-shaped
  # input (an integer-valued %Usage{} struct or map).
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: as_count(Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")),
      output_tokens: as_count(Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens"))
    }
  end

  defp normalize_usage(_usage), do: %{input_tokens: 0, output_tokens: 0}

  defp as_count(n) when is_integer(n), do: n
  defp as_count(_), do: 0

  # Once per process per model: the guard runs inside the session's process,
  # so a process-dictionary flag is exactly the "warn once per run" scope.
  defp maybe_warn_pricing_miss(model, usage) do
    key = {__MODULE__, :pricing_miss, model}

    unless Process.get(key) do
      Process.put(key, true)
      :telemetry.execute([:mimir, :guard, :pricing_miss], %{}, %{model: model, usage: usage})
    end

    :ok
  end
end
