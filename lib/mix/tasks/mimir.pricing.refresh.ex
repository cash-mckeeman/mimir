defmodule Mix.Tasks.Mimir.Pricing.Refresh do
  @moduledoc """
  Refresh the vendored token-pricing DB used by `Mimir.Pricing`.

  Pulls the community LiteLLM pricing table (`model_prices_and_context_window.json`
  — the same source `ccusage` uses) and writes it **gzipped** to
  `priv/pricing/litellm_model_prices.json.gz` (kept small; gunzipped on load).

  Rates are vendored (no network on the hot path). Run this task manually when
  rates drift. The app reads the vendored copy at runtime via `Mimir.Pricing`.

      mix mimir.pricing.refresh
      mix mimir.pricing.refresh --url https://.../model_prices.json
      mix mimir.pricing.refresh --dest priv/pricing/custom.json.gz

  ## Options

    * `--url <url>` — override the source URL (default: the LiteLLM `main` raw JSON)
    * `--dest <path>` — override the destination `.gz` file (default: the vendored priv path)
  """
  use Mix.Task

  @shortdoc "Refresh the vendored LiteLLM token-pricing DB"

  @default_url "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  @default_dest "priv/pricing/litellm_model_prices.json.gz"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [url: :string, dest: :string])
    url = opts[:url] || @default_url
    dest = opts[:dest] || @default_dest

    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Validate it parses and count models before writing (gzipped).
        count = body |> Jason.decode!() |> map_size()
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, :zlib.gzip(body))
        Mix.shell().info("[mimir.pricing] refreshed #{dest} — #{count} models from #{url}")

      {:ok, %{status: status}} ->
        Mix.raise("mimir.pricing.refresh failed: HTTP #{status} from #{url}")

      {:error, reason} ->
        Mix.raise("mimir.pricing.refresh failed: #{inspect(reason)}")
    end
  end
end
