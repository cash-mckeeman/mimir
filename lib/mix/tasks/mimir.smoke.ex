defmodule Mix.Tasks.Mimir.Smoke do
  @shortdoc "End-to-end smoke: descriptor → oracle → decision record → pricing → events → HTTP client"

  @moduledoc """
  Drives the public `mimir` API surface end-to-end as one repeatable command —
  no network, no external services. The HTTP client stage runs a real `Req`
  request against an in-process plug, so JSON encoding, response atomization,
  and error mapping execute production code at the transport seam. The health
  and turn-event stages run the real GenServers, ETS tables, and telemetry
  handlers.

  ## Stages

  1. descriptor — full parse incl. agent identity + outcome hint; rejection path
  2. catalog — resolver seam keeps/drops entries
  3. oracle — placement on a healthy catalog; no-candidate on empty and on degraded-lane catalogs
  4. decision record — id format, grant echo, agent echo
  5. route log — meta building for placed and grant-failed outcomes
  6. pricing — config-table math, vendored-DB load, unknown-model zero
  7. health — telemetry-driven degradation and recovery
  8. turn events — current-request buffering, ordering, envelope shape
  9. router client — placement round-trip and http_error mapping over a real Req request (skipped unless run under `MIX_ENV=test` — Plug is a test-only dependency; CI's test job runs it for real)
  10. redact — provider split, truncation, payload gating
  11. guard — grant guard halts at budget; caps guard halts at turns
  12. sessions — route response assembled into session opts; ingest correlated by decision_id

  ## Usage

      mix mimir.smoke

  Exits 0 on all-pass, non-zero on any failure. `run_smoke/0` is also
  asserted by the test suite so CI verifies the composed surface on every
  build.
  """

  use Mix.Task

  # Plug is a test-only dependency (mix.exs `only: :test`) — it (and Req.Test,
  # which calls into it) is only compiled under MIX_ENV=test. The router-client
  # stage's Plug-based body is guarded by this flag so it's dead-code-eliminated
  # under other envs. Locally, `mix quality` runs under the ambient dev
  # environment, so it never compiles the gated branch — but CI's dialyzer job
  # inherits the workflow-level `MIX_ENV=test` and DOES analyze it.
  # `Mimir.RouterClient.HTTP` itself is a normal (always-compiled) library
  # module, so it's aliased unconditionally below — only the literal
  # `Plug.Conn` / `Req.Test` calls need gating. The real, Plug-backed check
  # runs wherever MIX_ENV=test — `mix test` and the `mix mimir.smoke` CI step,
  # which lives in the test job (MIX_ENV=test).
  @plug_loaded? Mix.env() == :test

  alias Mimir.{
    Catalog,
    DecisionRecord,
    Descriptor,
    Health,
    Oracle,
    Pricing,
    Redact,
    RouteLog,
    Snapshot,
    TurnEvents
  }

  alias Mimir.Oracle.{Decision, Policy}
  alias Mimir.TurnEvents.GenAI

  @model "anthropic:claude-sonnet-4-6"
  @rates %{@model => %{input: 3_000_000, output: 15_000_000}}
  @catalog_config [
    %{id: "claude", model: @model, lane: "anthropic", runtime: "managed", capabilities: [:tools]}
  ]

  @impl Mix.Task
  def run(_args) do
    # Mix.Task does not auto-start the app or its deps (unlike `mix test`,
    # which starts the app tree before running ExUnit). The health/turn-events
    # stages need :telemetry (and the app's own deps) running, so start them
    # explicitly before driving any stage.
    Mix.Task.run("app.start")

    case run_smoke() do
      {:ok, results} ->
        print_results(results)
        passes = Enum.count(results, fn {_, s, _} -> s == :pass end)
        skips = Enum.count(results, fn {_, s, _} -> s == :skip end)

        msg =
          if skips > 0 do
            "#{passes} stages passed, #{skips} skipped."
          else
            "All #{length(results)} stages passed."
          end

        Mix.shell().info("\n#{msg}")
        :ok

      {:error, results} ->
        print_results(results)
        fails = Enum.count(results, fn {_, s, _} -> s == :fail end)
        Mix.raise("#{fails} smoke stage(s) failed.")
    end
  end

  @doc """
  Pure smoke flow — returns `{:ok, results}` or `{:error, results}` where
  `results` is a list of `{stage_name, :pass | :fail | :skip, detail}`. Does not
  print or halt; suitable for calling directly from tests.
  """
  @spec run_smoke() ::
          {:ok, [{String.t(), :pass | :fail | :skip, String.t()}]}
          | {:error, [{String.t(), :pass | :fail | :skip, String.t()}]}
  def run_smoke do
    ensure_servers()

    results = [
      stage("descriptor parse + rejection", &descriptor_stage/0),
      stage("catalog resolver seam", &catalog_stage/0),
      stage("oracle placement + no_candidate", &oracle_stage/0),
      stage("decision record", &decision_record_stage/0),
      stage("route log meta", &route_log_stage/0),
      stage("pricing (config + vendored DB)", &pricing_stage/0),
      stage("health degradation via telemetry", &health_stage/0),
      stage("turn events buffering", &turn_events_stage/0),
      stage("router HTTP client round-trip", &router_client_stage/0),
      stage("redact helpers", &redact_stage/0),
      stage("guard budget + caps halts", &guard_stage/0),
      stage("sessions opts + ingest correlation", &sessions_stage/0)
    ]

    if Enum.any?(results, &match?({_, :fail, _}, &1)), do: {:error, results}, else: {:ok, results}
  end

  defp stage(name, fun) do
    case fun.() do
      {:ok, detail} -> {name, :pass, detail}
      {:error, detail} -> {name, :fail, detail}
      {:skip, detail} -> {name, :skip, detail}
    end
  rescue
    e -> {name, :fail, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 500)}
  end

  defp ensure_servers do
    for server <- [Health, TurnEvents] do
      case server.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  # ── stages ────────────────────────────────────────────────────────────────

  defp descriptor_stage do
    {:ok, d} =
      Descriptor.parse(%{
        task_class: "extraction",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000,
        capabilities: ["tools"],
        agent: %{digest: "sha256:abc", name: "analyst", version: "1"},
        max_outcome_iterations: 3
      })

    true = d.agent.digest == "sha256:abc"
    true = d.max_outcome_iterations == 3
    {:error, {:invalid_descriptor, :task_class, _}} = Descriptor.parse(%{task_class: ""})
    {:ok, "parse + agent identity + rejection"}
  end

  defp catalog_stage do
    keep = fn m -> if m == @model, do: {:ok, :resolved}, else: {:error, :unknown_model} end

    [entry] =
      Catalog.entries(@catalog_config ++ [%{id: "bad", model: "nope:x", lane: "l", runtime: "r"}],
        resolve: keep
      )

    true = entry.model_spec == :resolved
    [identity] = Catalog.entries(@catalog_config)
    true = identity.model_spec == @model
    {:ok, "resolver kept 1/2, identity default works"}
  end

  defp oracle_stage do
    {:ok, d} =
      Descriptor.parse(%{
        task_class: "extraction",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000
      })

    entries = Catalog.entries(@catalog_config)
    healthy = Snapshot.assemble(pricing: @rates)

    {:decision, %Decision{entry: chosen}} = Oracle.decide(d, entries, %Policy{}, healthy)
    true = chosen.model == @model

    {:no_candidate, _reasons, _candidates} = Oracle.decide(d, [], %Policy{}, healthy)

    degraded = Snapshot.assemble(pricing: @rates, health: %{"anthropic" => :degraded})
    {:no_candidate, _r, _c} = Oracle.decide(d, entries, %Policy{}, degraded)

    {:ok, "placed on healthy lane; no_candidate on empty + degraded"}
  end

  defp decision_record_stage do
    {:ok, d} =
      Descriptor.parse(%{
        task_class: "extraction",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000,
        agent: %{digest: "sha256:abc"}
      })

    entries = Catalog.entries(@catalog_config)
    snapshot = Snapshot.assemble(pricing: @rates)
    {:decision, placement} = Oracle.decide(d, entries, %Policy{}, snapshot)

    rec =
      DecisionRecord.build(
        d,
        {:decision, placement},
        "grant-uuid-1",
        %{workflow_id: "wf", step_id: "s1"},
        snapshot
      )

    record = DecisionRecord.to_event(rec)

    "rd_" <> _ = record["decision_id"]
    true = record["grant_id"] == "grant-uuid-1"
    true = record["descriptor"]["agent"]["digest"] == "sha256:abc"
    true = record["verdict"]["outcome"] == "placement"
    {:ok, "decision_id #{String.slice(record["decision_id"], 0, 8)}…"}
  end

  defp route_log_stage do
    "req_route_" <> _ = RouteLog.gen_request_id()

    {:ok, d} =
      Descriptor.parse(%{
        task_class: "extraction",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000
      })

    snapshot = Snapshot.assemble(pricing: @rates)

    decision_record =
      DecisionRecord.build(
        d,
        {:no_candidate, [], []},
        nil,
        %{workflow_id: "wf", step_id: "s1"},
        snapshot
      )

    log = %Mimir.RouteLog{
      request_id: "req_route_smoke",
      caller: %{id: "vk-uuid", tenant_id: "t1"},
      correlation: %{workflow_id: "wf", step_id: "s1", parent_step_id: nil},
      outcome: {:grant_failed, :parent_exhausted},
      decision_record: decision_record
    }

    meta = RouteLog.to_meta(log, 0)
    true = meta.status == "error"
    true = meta.error_class == "grant_failed"
    [%{"type" => "routing_decision", "gen_ai" => payload}] = meta.gen_ai_events
    "rd_" <> _ = payload["decision_id"]
    {:ok, "grant_failed meta + routing_decision envelope"}
  end

  defp pricing_stage do
    previous = Application.get_env(:mimir, :pricing)
    Application.put_env(:mimir, :pricing, @rates)

    try do
      # 1000 in + 1000 out at the config rates → 3_000 + 15_000 µ$
      18_000 = Pricing.cost_microdollars(@model, %{input_tokens: 1_000, output_tokens: 1_000})
      0 = Pricing.cost_microdollars("unknown:model", %{input_tokens: 1_000, output_tokens: 1_000})

      # Vendored LiteLLM DB actually loads from priv and prices a well-known model.
      Application.delete_env(:mimir, :pricing)

      vendored =
        Pricing.cost_microdollars("openai:gpt-4o", %{input_tokens: 100_000, output_tokens: 0})

      if vendored > 0 do
        {:ok, "config math exact; vendored DB priced gpt-4o at #{vendored} µ$/100k input"}
      else
        {:error, "vendored DB returned 0 for openai:gpt-4o — DB not loading?"}
      end
    after
      if previous,
        do: Application.put_env(:mimir, :pricing, previous),
        else: Application.delete_env(:mimir, :pricing)
    end
  end

  defp health_stage do
    Application.put_env(:mimir, :completion_event, [:mimir, :smoke, :completion])

    try do
      Health.reset()
      :ok = Health.attach()

      for _ <- 1..3 do
        :telemetry.execute([:mimir, :smoke, :completion], %{}, %{model: @model, outcome: :error})
      end

      :degraded = Health.state("anthropic")

      :telemetry.execute([:mimir, :smoke, :completion], %{}, %{model: @model, outcome: :ok})
      :ok = Health.state("anthropic")
      {:ok, "3 failures → degraded; 1 success → recovered"}
    after
      Health.detach()
      Application.delete_env(:mimir, :completion_event)
      Health.reset()
    end
  end

  defp turn_events_stage do
    rid = "smoke-#{System.unique_integer([:positive])}"
    :ok = TurnEvents.put_current(rid)
    :ok = TurnEvents.append_current("chat", GenAI.usage(10, 5))
    :ok = TurnEvents.append_current("tool_use", GenAI.tool_use(%{name: "search", id: "t1"}))

    [first, second] = TurnEvents.take(rid)
    true = first["seq"] < second["seq"]
    true = first["type"] == "chat"
    true = first["gen_ai"]["gen_ai.usage.input_tokens"] == 10
    true = second["gen_ai"]["gen_ai.tool.name"] == "search"
    [] = TurnEvents.take(rid)
    {:ok, "2 events buffered, ordered, drained"}
  end

  if @plug_loaded? do
    alias Mimir.RouterClient.HTTP

    defp router_client_stage do
      if Code.ensure_loaded?(Req.Test) do
        body = %{
          "verdict" => "placement",
          "placement" => %{
            "lane" => "anthropic",
            "model" => @model,
            "runtime" => "managed",
            "reasons" => [],
            "candidates" => []
          },
          "grant" => %{"key" => "vk-grant", "expires_at" => nil, "budget_microdollars" => 50_000},
          "workflow_id" => "wf",
          "step_id" => "s1",
          "decision_id" => "rd_smoke",
          "snapshot_at" => "2026-07-04T00:00:00Z"
        }

        {:ok, resp} =
          HTTP.route(%{task_class: "extraction"},
            base_url: "http://router.smoke",
            bearer_token: "vk-parent",
            plug: fn conn -> Req.Test.json(conn, body) end
          )

        true = resp.verdict == :placement
        true = resp.placement.model == @model
        true = resp.grant.key == "vk-grant"

        {:error, {:http_error, 409, _}} =
          HTTP.route(%{},
            base_url: "http://router.smoke",
            bearer_token: "vk-parent",
            plug: fn conn -> Plug.Conn.send_resp(conn, 409, "{}") end
          )

        {:ok, "placement parsed to struct; 409 mapped to http_error"}
      else
        {:skip, "compiled under MIX_ENV=test but Req.Test is not loaded at runtime"}
      end
    end
  else
    # Plug (and Req.Test, which calls into it) is a test-only dependency —
    # not compiled under this MIX_ENV. This branch only exists so local
    # `mix quality` (which runs under the ambient dev environment) never
    # reference the unavailable module — it never compiles the gated branch
    # above. CI's dialyzer job inherits the workflow-level `MIX_ENV=test` and
    # DOES analyze that branch. The real check runs under MIX_ENV=test —
    # `mix test` and the `mix mimir.smoke` CI step (in the test job, which
    # sets MIX_ENV=test).
    defp router_client_stage do
      {:skip, "Plug is a test-only dependency; run under MIX_ENV=test for the real round trip"}
    end
  end

  defp redact_stage do
    {"anthropic", "claude-sonnet-4-6"} = Redact.split_provider(@model)
    {nil, nil} = Redact.payloads(%{"messages" => []}, %{"ok" => true}, false)
    truncated = Redact.truncate(String.duplicate("a", 100), 10)
    true = byte_size(truncated) <= 10
    {:ok, "provider split, payload gate, truncation"}
  end

  defp guard_stage do
    previous = Application.get_env(:mimir, :pricing)
    Application.put_env(:mimir, :pricing, @rates)

    try do
      guard = Mimir.Guard.for_grant(%{budget_microdollars: 18_000}, @model)
      :cont = guard.(%{usage: %{input_tokens: 10, output_tokens: 10}, turns: 1})

      {:halt, {:budget_exceeded, _}} =
        guard.(%{usage: %{input_tokens: 1_000, output_tokens: 1_000}, turns: 2})

      {:halt, {:max_turns, _}} =
        Mimir.Guard.caps(max_turns: 3).(%{usage: %{}, turns: 3})

      {:ok, "grant guard halts at budget; caps halt at turns"}
    after
      if previous,
        do: Application.put_env(:mimir, :pricing, previous),
        else: Application.delete_env(:mimir, :pricing)
    end
  end

  defp sessions_stage do
    resp = %{
      verdict: "placement",
      placement: %{
        lane: "anthropic",
        model: @model,
        runtime: "managed",
        reasons: [],
        candidates: []
      },
      grant: %{key: "vk-grant", expires_at: nil, budget_microdollars: 50_000},
      workflow_id: "wf",
      step_id: "s1",
      decision_id: "rd_smoke",
      snapshot_at: "2026-07-04T00:00:00Z"
    }

    opts = Mimir.Sessions.opts(resp, base_url: "https://gw.example/v1", request_id: "req_smoke")
    true = opts[:model_config].api_key == "vk-grant"
    true = opts[:telemetry_metadata].decision_id == "rd_smoke"
    true = is_function(opts[:turn_guard], 1)

    # Ingest: the recipe's correlation flows into buffered events.
    ctx = Mimir.Ingest.from_route(resp, "req_smoke")
    :ok = Mimir.Ingest.handle_event(ctx, %{"type" => "rma.text_delta", "text" => "hi"})
    [event] = Mimir.TurnEvents.take("req_smoke")
    true = event["gen_ai"]["decision_id"] == "rd_smoke"

    {:ok, "opts assembled; ingest correlated by decision_id"}
  end

  defp print_results(results) do
    for {name, status, detail} <- results do
      tag =
        case status do
          :pass -> "[PASS]"
          :fail -> "[FAIL]"
          :skip -> "[SKIP]"
        end

      suffix = if detail == "", do: "", else: " — #{detail}"
      Mix.shell().info("#{tag} #{name}#{suffix}")
    end
  end
end
