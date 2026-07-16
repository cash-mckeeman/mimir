# Routed grants: the fleet shape — route through a live router service.
#
# `examples/gateway_less.exs` consulted the oracle in-process, with no minted
# keys and no fleet behind it. This example is the other shape Mimir
# supports: a gateway service built on this library, exposing
# `POST /v1/route`, that owns the fleet's budget state and mints scoped
# bearer tokens ("grants") for the caller to use against the routed model.
# `Mimir.RouterClient.HTTP` is the thin Req-based client for that call — this
# library ships the client; the router service itself is the embedder's, not
# this library's.
#
# Prerequisites: a router service to point at. There is no public router this
# example can call for you — you need your own gateway built on Mimir,
# exposing `POST /v1/route` and issuing bearer tokens.
#
#     ROUTER_URL=https://your-gateway.example.com \
#     ROUTER_KEY=your-bearer-token \
#     mix run examples/routed_grants.exs
#
# Missing either variable prints this same guidance and exits 0 rather than
# crashing — there's nothing to demonstrate without a router to call.

router_url = System.get_env("ROUTER_URL")
router_key = System.get_env("ROUTER_KEY")

if is_nil(router_url) or is_nil(router_key) do
  IO.puts("""
  routed_grants.exs needs a live router service to call — Mimir doesn't ship
  or host one; it's the client library a gateway is built on.

  Set both env vars and re-run:

      ROUTER_URL=https://your-gateway.example.com \\
      ROUTER_KEY=your-bearer-token \\
      mix run examples/routed_grants.exs

  ROUTER_URL is the gateway's base URL (no trailing /v1/route — the client
  appends that path). ROUTER_KEY is a bearer token your gateway issued you.

  See examples/gateway_less.exs for the no-service alternative: the same
  oracle, consulted in-process, with no router and no minted keys.
  """)

  System.halt(0)
end

{:ok, _} = Application.ensure_all_started(:mimir)

# ── 1. Build the descriptor exactly as the in-process example did ───────────
#
# The router service validates and re-parses this shape server-side via the
# same `Mimir.Descriptor.parse/1` contract — sending a map here is enough; you
# don't need to construct the struct client-side.
{:ok, descriptor} =
  Mimir.Descriptor.parse(%{
    task_class: "extraction",
    budget_ceiling_microdollars: 50_000,
    latency_tolerance_ms: 30_000,
    expected_tokens: %{in: 2_000, out: 500},
    capabilities: [:tools],
    agent: %{digest: "sha256:9f2c...a01", name: "invoice-extractor", version: "1.4.0"}
  })

request = %{
  task_class: descriptor.task_class,
  budget_ceiling_microdollars: descriptor.budget_ceiling_microdollars,
  latency_tolerance_ms: descriptor.latency_tolerance_ms,
  expected_tokens: descriptor.expected_tokens,
  capabilities: descriptor.capabilities,
  agent: descriptor.agent,
  workflow_id: "wf_demo_001",
  step_id: "step_extract"
}

# ── 2. Call the router ───────────────────────────────────────────────────────
#
# `Mimir.RouterClient.HTTP.route/2` POSTs to `#{base_url}/v1/route` with a
# bearer `Authorization` header and parses the JSON response into a
# `%Mimir.RouteResponse{}` via `Mimir.RouteResponse.new/1` — the single struct
# boundary. Every field below is a struct field, never a raw map key.
case Mimir.RouterClient.HTTP.route(request, base_url: router_url, bearer_token: router_key) do
  {:ok, %Mimir.RouteResponse{verdict: :placement} = response} ->
    placement = response.placement
    grant = response.grant

    # NEVER print a bearer token in full. Only its prefix + length — enough to
    # confirm you got a distinct, well-formed key without leaking it into logs
    # or terminal scrollback.
    masked_key =
      case grant.key do
        key when is_binary(key) and byte_size(key) > 8 ->
          "#{binary_part(key, 0, 8)}... (#{byte_size(key)} chars)"

        key when is_binary(key) ->
          "(#{byte_size(key)} chars)"

        _ ->
          "(no key returned)"
      end

    IO.puts("""

    placement:   #{placement.model} (lane #{placement.lane}, runtime #{placement.runtime})
    decision_id: #{response.decision_id}
    grant key:   #{masked_key}
    expires_at:  #{grant.expires_at}

    Where this attaches: the granted key + this same #{router_url} become the
    session's model config — e.g. `base_url: "#{router_url}", api_key: <the grant key>`
    wherever your LLM client reads its connection options. Every call made
    with that key is enforced against the grant's budget on the SERVER side
    (the gateway's data plane), not by anything in this script — the client
    never needs to track spend itself.
    """)

  {:ok, %Mimir.RouteResponse{verdict: :no_candidate} = response} ->
    IO.puts("""

    no_candidate — the router had nothing viable for this descriptor.
    decision_id: #{response.decision_id}
    reasons:     #{inspect(response.reasons)}
    """)

  {:error, {:http_error, status, body}} ->
    IO.puts("""

    router returned an HTTP error.
    status: #{status}
    body:   #{inspect(body)}
    """)

  {:error, reason} ->
    IO.puts("""

    router call failed before a response came back (network, DNS, TLS, etc).
    reason: #{inspect(reason)}
    """)
end
