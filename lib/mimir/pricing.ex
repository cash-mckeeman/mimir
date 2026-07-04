defmodule Mimir.Pricing do
  @moduledoc """
  Token usage -> integer microdollar cost.

  Lookup order for a `"provider:model_id"` key:

    1. Config table (`:mimir, :pricing`) keyed `"provider:model_id"` — wins when present.
    2. Vendored LiteLLM pricing DB fallback (loaded once, memoized in `:persistent_term`):
       - try bare `model_id` key in the DB
       - then `"<provider>/<model_id>"`
    3. Miss → zero (never crashes metering).

  Price table (`:mimir, :pricing`) values are `%{input: µ$_per_million, output: µ$_per_million}`.
  The vendored DB stores the same shape after converting LiteLLM's USD/token floats at load time:
  `round(cost * 1.0e12)` → integer µ$/M tokens. Integer math only on the hot path.

  Refresh the vendored DB with `mix mimir.pricing.refresh`. The `:mimir, :pricing_db_path`
  config key overrides the default priv path (useful in tests).
  """

  require Logger

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer()
        }

  @spec cost_microdollars(String.t(), usage()) :: non_neg_integer()
  def cost_microdollars(model, usage) when is_binary(model) and is_map(usage) do
    %{input: in_rate, output: out_rate} = price(model)
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    div(input * in_rate, 1_000_000) + div(output * out_rate, 1_000_000)
  end

  # (1) config table wins; (2) vendored DB fallback; (3) zero default.
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

  # Converts raw LiteLLM JSON map to %{model_key => %{input: µ$/M, output: µ$/M}}.
  # Entries missing input_cost_per_token or output_cost_per_token are skipped.
  # Conversion: round(usd_per_token * 1.0e12) = µ$/M tokens.
  defp convert_db(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn
      {key, %{"input_cost_per_token" => inp, "output_cost_per_token" => out}}, acc
      when is_number(inp) and is_number(out) ->
        Map.put(acc, key, %{
          input: round(inp * 1.0e12),
          output: round(out * 1.0e12)
        })

      _other, acc ->
        acc
    end)
  end

  defp maybe_gunzip(body, path) do
    if String.ends_with?(path, ".gz"), do: :zlib.gunzip(body), else: body
  end

  defp default_pricing_path do
    Application.app_dir(:mimir, "priv/pricing/litellm_model_prices.json.gz")
  end
end
