defmodule Mimir.Guard do
  @moduledoc """
  Turn-guard builders for a session loop's between-turn hook (RMA's
  `turn_guard:` option; 0.5.0+, hook shape unchanged through 0.10). Plain
  data in, plain verdict out — no RMA types.

  `for_grant/3` prices the session's accumulated usage with `Mimir.Pricing`
  and halts once the grant budget is spent — the control-plane soft half of
  enforcement, for runtimes where the gateway cannot sit in the data plane.
  `caps/1` is the mimir-less form: plain cost/token/turn caps, no minted key.

  A cost cap (the grant budget, or `caps/1`'s `:max_cost_microdollars`) prices
  cache tokens too — cache_read_input_tokens and cache_creation_input_tokens
  are part of the usage map Guard prices through `Mimir.Pricing`, the same
  as input/output, because cost is cost. `:max_total_tokens` stays input +
  output only.

  Guards never raise mid-run, but the two cost-check failures aren't the
  same outcome: a pricing-table miss (no rate anywhere for the model)
  degrades to `:cont`, leaving whatever caps remain to decide, and emits a
  `[:mimir, :guard, :pricing_miss]` telemetry warning once per process per
  model. A misconfigured pricing entry — `Mimir.Pricing` raising
  `Mimir.Pricing.InvalidConfigError` for an invalid rate or an unknown key
  — halts instead, with `{:invalid_pricing, %{model:, usage:, message:}}`,
  rather than letting the raise propagate: a bad config entry is a real
  problem the caller should stop and look at, not one the guard can
  shrug off the way it does a merely-unpriced model.
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

    case price(model, usage) do
      {:ok, cost} ->
        cond do
          cost == 0 and usage.input_tokens + usage.output_tokens > 0 ->
            maybe_warn_pricing_miss(model, usage)
            :cont

          cost >= budget ->
            {:halt,
             {:budget_exceeded,
              %{cost_microdollars: cost, budget_microdollars: budget, usage: usage}}}

          true ->
            :cont
        end

      {:error, message} ->
        {:halt, {:invalid_pricing, %{model: model, usage: usage, message: message}}}
    end
  end

  # Mimir.Pricing raises Mimir.Pricing.InvalidConfigError for a misconfigured
  # entry (an invalid rate, an unknown key) — loud by design, since a
  # silently-wrong price is worse than a crash almost everywhere else. A
  # guard runs mid-session, though, so a raise here would violate "never
  # raise mid-run"; this turns it into a result the guard can halt on
  # instead. Rescuing this exception specifically, not ArgumentError, means
  # an unrelated ArgumentError from the same call — a packaging bug, a BIF
  # badarg, anything that is not a pricing-config problem — still raises
  # instead of being misreported as :invalid_pricing.
  defp price(model, usage) do
    {:ok, Mimir.Pricing.cost_microdollars(model, usage)}
  rescue
    e in Mimir.Pricing.InvalidConfigError -> {:error, Exception.message(e)}
  end

  # Map.get accepts structs and atom- or string-keyed maps without Access.
  # Invalid usage or token counts contribute zero rather than raising mid-session.
  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: as_count(Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")),
      output_tokens: as_count(Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")),
      cache_read_input_tokens:
        as_count(
          Map.get(usage, :cache_read_input_tokens) || Map.get(usage, "cache_read_input_tokens")
        ),
      cache_creation_input_tokens:
        as_count(
          Map.get(usage, :cache_creation_input_tokens) ||
            Map.get(usage, "cache_creation_input_tokens")
        )
    }
  end

  defp normalize_usage(_usage),
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }

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
