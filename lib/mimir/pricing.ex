defmodule Mimir.Pricing do
  @moduledoc """
  Token usage -> integer microdollar cost.

  Lookup order for a `"provider:model_id"` key:

    1. Config table (`:mimir, :pricing`) keyed `"provider:model_id"` — wins when present.
    2. Vendored LiteLLM pricing DB fallback (loaded once, memoized in `:persistent_term`):
       - try bare `model_id` key in the DB
       - then `"<provider>/<model_id>"`
    3. Miss → zero (never crashes metering).

  Rates are integer µ$ per million tokens: `input:` and `output:`, plus optional
  `cache_read:` and `cache_write:`. The vendored DB stores the same shape after converting
  LiteLLM's USD/token floats at load time: `round(cost * 1.0e12)` → integer µ$/M tokens.
  Integer math only on the hot path.

  Cache tokens (`:cache_read_input_tokens`, `:cache_creation_input_tokens`) price at the
  cache rates. A cache rate that is missing, or zero in the vendored DB, prices those
  tokens at the model's input rate instead, never as free, and emits
  `[:mimir, :pricing, :no_cache_rate]` with the token counts so priced as measurements and
  `%{model: model}` as metadata. It fires only when such tokens are present.

  Refresh the vendored DB with `mix mimir.pricing.refresh`. The `:mimir, :pricing_db_path`
  config key overrides the default priv path (useful in tests).
  """

  require Logger

  @typedoc "Integer µ$ per million tokens: a config-table entry, or a vendored DB entry."
  @type rates :: %{
          required(:input) => non_neg_integer(),
          required(:output) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:cache_write) => non_neg_integer()
        }

  @typedoc "Token counts, atom-keyed; a missing key counts as zero."
  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer(),
          optional(:cache_creation_input_tokens) => non_neg_integer()
        }

  @doc """
  Cost of `usage` against `model`'s rate, in integer microdollars. Looks up
  the rate via the lookup order documented above; an unpriced model costs 0.
  """
  @spec cost_microdollars(String.t(), usage()) :: non_neg_integer()
  def cost_microdollars(model, usage) when is_binary(model) and is_map(usage) do
    rates = price(model)
    cache_read = Map.get(usage, :cache_read_input_tokens, 0)
    cache_write = Map.get(usage, :cache_creation_input_tokens, 0)
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

  # (1) config table wins; (2) vendored DB fallback; (3) zero default.
  @spec price(String.t()) :: rates()
  defp price(model) do
    config_table = Application.get_env(:mimir, :pricing, %{})

    case Map.get(config_table, model) do
      %{input: _, output: _} = rate ->
        rate

      _ ->
        vendored_price(model) || %{input: 0, output: 0}
    end
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
