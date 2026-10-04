defmodule Mimir.RouterClient.HTTP do
  @moduledoc """
  `RouterClient` implementation that calls `POST /v1/route` over HTTP via Req.

  ## Options

  - `:base_url` (required) — e.g. `"https://gateway.example.com"`.
  - `:bearer_token` (required) — the caller's bearer token.
  - `:plug` (optional) — a plug (module or function) handling the request
    in-process instead of a live HTTP call — the `Req.Test` seam; used by
    this library's own tests and smoke task.

  ## Response normalization

  The JSON response (string keys) is parsed into a `%Mimir.RouteResponse{}` by
  `Mimir.RouteResponse.new/1` — the single struct boundary; this client
  performs no key atomization of its own.
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
        Mimir.RouteResponse.new(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
