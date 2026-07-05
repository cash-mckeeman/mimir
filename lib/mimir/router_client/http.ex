defmodule Mimir.RouterClient.HTTP do
  @moduledoc """
  `RouterClient` implementation that calls `POST /v1/route` over HTTP via Req.
  Normalizes the JSON response to atom-keyed maps so the shape is identical to
  an in-process implementation.

  ## Options

  - `:base_url` (required) — e.g. `"https://gateway.example.com"`.
  - `:bearer_token` (required) — the `vk-…` plaintext key.

  ## Response normalization

  The HTTP response is JSON with string keys. This impl atomizes the top-level
  keys and the nested `placement`, `grant`, and `candidates` maps so callers
  can use atom access — matching the in-process response shape.
  """
  @behaviour Mimir.RouterClient

  @impl true
  def route(request, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    bearer = Keyword.fetch!(opts, :bearer_token)

    url = base_url <> "/v1/route"

    req_opts =
      [
        json: request,
        headers: [{"authorization", "Bearer #{bearer}"}],
        retry: false,
        receive_timeout: 30_000
      ]
      |> then(fn o ->
        case opts[:plug] do
          nil -> o
          plug -> Keyword.put(o, :plug, plug)
        end
      end)

    case Req.post(url, req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ── response normalization ───────────────────────────────────────────────

  # Atomize the top-level response keys and the nested placement/grant/candidates
  # maps so the shape is identical to an in-process implementation.
  defp normalize(body) when is_map(body) do
    body
    |> atomize()
    |> normalize_nested()
  end

  defp normalize(body), do: body

  defp normalize_nested(%{placement: placement} = resp) when is_map(placement) do
    %{resp | placement: normalize_placement(placement)}
    |> normalize_grant()
  end

  defp normalize_nested(resp) do
    # Normalize the top-level :candidates list present on no_candidate responses.
    candidates = Map.get(resp, :candidates, [])

    resp
    |> Map.put(:candidates, Enum.map(candidates, &atomize/1))
    |> normalize_grant()
  end

  defp normalize_grant(%{grant: grant} = resp) when is_map(grant) do
    %{resp | grant: atomize(grant)}
  end

  defp normalize_grant(resp), do: resp

  defp normalize_placement(placement) when is_map(placement) do
    atomized = atomize(placement)
    candidates = Map.get(atomized, :candidates, [])
    %{atomized | candidates: Enum.map(candidates, &atomize/1)}
  end

  defp atomize(m) when is_map(m) do
    Map.new(m, fn {k, v} ->
      atom = if is_atom(k), do: k, else: String.to_existing_atom(k)
      {atom, v}
    end)
  rescue
    # Unknown atom key — return as-is with string key rather than crashing.
    ArgumentError ->
      Map.new(m, fn {k, v} ->
        atom = if is_atom(k), do: k, else: safe_atom(k)
        {atom, v}
      end)
  end

  defp safe_atom(k) when is_binary(k) do
    # Only create atoms for known top-level response keys to avoid atom table growth.
    known = ~w(verdict placement grant workflow_id step_id decision_id snapshot_at
               reasons candidates lane model runtime key expires_at budget_microdollars
               id error reason)

    if k in known, do: String.to_atom(k), else: k
  end
end
