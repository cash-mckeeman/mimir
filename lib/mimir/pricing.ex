defmodule Mimir.Pricing do
  @moduledoc """
  Token usage -> integer microdollar cost.

  Rates are integer µ$ per million tokens: `input:`, `output:`, and optional
  `cache_read:` and `cache_write:`. Each rate resolves on its own for a
  `"provider:model_id"` key:

    1. the config table (`:mimir, :pricing`) entry, when it sets that rate;
    2. the vendored LiteLLM pricing DB (loaded once, memoized in `:persistent_term`),
       trying the bare `model_id`, then `"<provider>/<model_id>"`;
    3. zero for `input` and `output`, so an unpriced model never crashes metering.

  A config entry that sets only `input:` and `output:` (a negotiated rate, say) still
  takes the vendored DB's list cache rates unless it sets its own.

  An explicit `0` in a config entry is honored as the operator's rate: that field
  prices free, same as any other rate the config table sets. This differs from a
  zero in the vendored DB, which counts as missing (below) — the DB's zero marks an
  untracked cost LiteLLM hasn't filled in, not a negotiated zero-cost rate.

  A misconfigured entry is loud: a key outside `input:`/`output:`/`cache_read:`/
  `cache_write:`, or a rate that isn't a non-negative integer, raises `ArgumentError`
  naming the model and the offending key/value, the first time that model's rate is
  resolved.

  Cache tokens (`:cache_read_input_tokens`, `:cache_creation_input_tokens`) price at the
  cache rates. With no cache rate from either source they price at the input rate rather
  than at zero by default — an unpriced model's input rate is itself 0, though, so its
  cache tokens still cost 0, same as before — and `[:mimir, :pricing, :no_cache_rate]`
  fires, only when such tokens are present. Its measurements are the token counts priced
  that way; its metadata is `%{model: model}`. A zero cache cost in the vendored DB counts
  as no rate.

  The vendored DB is converted from LiteLLM's USD/token floats at load time:
  `round(cost * 1.0e12)` → integer µ$/M tokens, so the hot path is integer math only.
  Refresh it with `mix mimir.pricing.refresh`; `:mimir, :pricing_db_path` overrides its
  path (useful in tests).
  """

  require Logger

  @rate_fields [:input, :output, :cache_read, :cache_write]

  @typedoc "Integer µ$ per million tokens: a config-table entry, or a vendored DB entry."
  @type rates :: %{
          required(:input) => non_neg_integer(),
          required(:output) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:cache_write) => non_neg_integer()
        }

  @typedoc """
  Token counts, atom-keyed; a missing key counts as zero. The two cache keys
  also tolerate an explicit `nil` (as zero), since a caller passing a decoded
  wire map straight through may hand one over for an absent cache count.
  """
  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer() | nil,
          optional(:cache_creation_input_tokens) => non_neg_integer() | nil
        }

  @doc """
  Cost of `usage` against `model`'s rates, in integer microdollars. Resolves
  the rates as documented above; an unpriced model costs 0.
  """
  @spec cost_microdollars(String.t(), usage()) :: non_neg_integer()
  def cost_microdollars(model, usage) when is_binary(model) and is_map(usage) do
    rates = configured_price(model)
    cache_read = Map.get(usage, :cache_read_input_tokens, 0) || 0
    cache_write = Map.get(usage, :cache_creation_input_tokens, 0) || 0
    report_missing_cache_rates(model, rates, cache_read, cache_write)

    per_million(Map.get(usage, :input_tokens, 0), rates.input) +
      per_million(Map.get(usage, :output_tokens, 0), rates.output) +
      per_million(cache_read, Map.get(rates, :cache_read, rates.input)) +
      per_million(cache_write, Map.get(rates, :cache_write, rates.input))
  end

  defp per_million(tokens, rate), do: div(tokens * rate, 1_000_000)

  defp report_missing_cache_rates(model, rates, cache_read, cache_write) do
    unpriced_read = if Map.has_key?(rates, :cache_read), do: 0, else: cache_read
    unpriced_write = if Map.has_key?(rates, :cache_write), do: 0, else: cache_write

    if unpriced_read + unpriced_write > 0 do
      :telemetry.execute(
        [:mimir, :pricing, :no_cache_rate],
        %{cache_read_input_tokens: unpriced_read, cache_creation_input_tokens: unpriced_write},
        %{model: model}
      )
    end

    :ok
  end

  @doc """
  Resolves `model`'s full rate map from an explicit config `entry`, which
  may be partial (or `%{}`, or absent a key entirely). Every field —
  `input`, `output`, `cache_read`, `cache_write` — resolves on its own: the
  entry's rate when it sets one, else the vendored DB's, else zero for
  `input`/`output` (cache rates may stay absent). This is the same
  per-field rule `cost_microdollars/2` applies to the `:mimir, :pricing`
  table; `Mimir.Snapshot`/`Mimir.Oracle` call it directly so a snapshot's
  own pricing table — which may hold the same kind of partial entry —
  resolves identically instead of being read as a bare `%{input:, output:}`
  pair.
  """
  @spec resolve_rates(String.t(), map()) :: rates()
  def resolve_rates(model, entry) when is_binary(model) do
    %{input: 0, output: 0}
    |> Map.merge(vendored_price(model) || %{})
    |> Map.merge(configured_rates(model, entry))
  end

  # Per field: config entry, then vendored DB; cache rates may stay absent.
  @spec configured_price(String.t()) :: rates()
  defp configured_price(model) do
    entry =
      :mimir
      |> Application.get_env(:pricing, %{})
      |> Map.get(model, %{})

    resolve_rates(model, entry)
  end

  # A misconfigured entry is loud, not silently dropped: an unknown key or an
  # invalid rate value raises ArgumentError naming the model and the
  # offending key/value, at the point of use.
  defp configured_rates(model, entry) when is_map(entry) do
    Map.new(entry, fn {field, rate} -> {field, validate_rate!(model, field, rate)} end)
  end

  defp configured_rates(_model, _entry), do: %{}

  defp validate_rate!(model, field, rate) do
    unless field in @rate_fields do
      raise ArgumentError,
            "Mimir.Pricing: model #{inspect(model)} has an unknown pricing key " <>
              "#{inspect(field)} (expected one of #{inspect(@rate_fields)})"
    end

    unless is_integer(rate) and rate >= 0 do
      raise ArgumentError,
            "Mimir.Pricing: model #{inspect(model)} has an invalid #{field} rate: " <>
              "#{inspect(rate)} (expected a non-negative integer)"
    end

    rate
  end

  # Vendored DB lookup: try bare model_id, then "provider/model_id".
  defp vendored_price(model) do
    db = pricing_db()

    case String.split(model, ":", parts: 2) do
      [provider, model_id] ->
        Map.get(db, model_id) || Map.get(db, "#{provider}/#{model_id}")

      _ ->
        nil
    end
  end

  # Loads the vendored pricing DB once per path (memoized in :persistent_term).
  # .gz paths are gunzipped; missing/corrupt file → log warning once, return empty map.
  defp pricing_db do
    path = Application.get_env(:mimir, :pricing_db_path) || default_pricing_path()
    key = {__MODULE__, :pricing_db, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        db = load_pricing_db(path)
        :persistent_term.put(key, db)
        db

      db ->
        db
    end
  end

  defp load_pricing_db(path) do
    with {:ok, body} <- File.read(path),
         decompressed <- maybe_gunzip(body, path),
         {:ok, raw} <- Jason.decode(decompressed) do
      convert_db(raw)
    else
      {:error, reason} ->
        Logger.warning(
          "Mimir.Pricing: could not load pricing DB at #{inspect(path)}: #{inspect(reason)}"
        )

        %{}
    end
  rescue
    e ->
      Logger.warning(
        "Mimir.Pricing: failed to parse pricing DB at #{inspect(path)}: #{Exception.message(e)}"
      )

      %{}
  end

  # Converts raw LiteLLM JSON map to %{model_key => rates}, in µ$/M tokens.
  # Entries missing input_cost_per_token or output_cost_per_token are skipped.
  # A cache cost is kept only when positive: LiteLLM writes 0.0 for some cache
  # costs, and a zero here would price cached tokens as free.
  # Conversion: round(usd_per_token * 1.0e12) = µ$/M tokens.
  defp convert_db(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn
      {key, %{"input_cost_per_token" => inp, "output_cost_per_token" => out} = entry}, acc
      when is_number(inp) and is_number(out) ->
        rates =
          %{input: round(inp * 1.0e12), output: round(out * 1.0e12)}
          |> put_cache_rate(:cache_read, entry["cache_read_input_token_cost"])
          |> put_cache_rate(:cache_write, entry["cache_creation_input_token_cost"])

        Map.put(acc, key, rates)

      _other, acc ->
        acc
    end)
  end

  defp put_cache_rate(rates, field, cost) when is_number(cost) and cost > 0,
    do: Map.put(rates, field, round(cost * 1.0e12))

  defp put_cache_rate(rates, _field, _cost), do: rates

  defp maybe_gunzip(body, path) do
    if String.ends_with?(path, ".gz"), do: :zlib.gunzip(body), else: body
  end

  defp default_pricing_path do
    Application.app_dir(:mimir, "priv/pricing/litellm_model_prices.json.gz")
  end
end
