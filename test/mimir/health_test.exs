defmodule Mimir.HealthTest do
  # async: false — Health uses a named ETS table and a global telemetry handler;
  # concurrent tests would interfere with streak state and handler registration.
  use ExUnit.Case, async: false

  alias Mimir.Health

  setup_all do
    case start_supervised(Health) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    # Wipe all streaks before each test so prior runs don't bleed through.
    Health.reset()

    # Default the configured completion event to a custom example value,
    # since this library attaches no handler at boot (no supervision tree).
    # Tests below can override this for their own purposes.
    Application.put_env(:mimir, :completion_event, [:example_app, :completion])
    on_exit(fn -> Application.delete_env(:mimir, :completion_event) end)

    :ok
  end

  # ── handler attachment ───────────────────────────────────────────────────

  describe "handler attachment" do
    test "Health handler is attached to the configured completion event" do
      :ok = Health.attach()
      on_exit(fn -> :telemetry.detach("mimir-router-health") end)

      handlers = :telemetry.list_handlers([:example_app, :completion])
      assert Enum.any?(handlers, &(&1.id == "mimir-router-health"))
    end
  end

  # ── streak semantics ─────────────────────────────────────────────────────

  describe "streak semantics" do
    test "unknown lane is :ok" do
      assert Health.state("unknown_lane") == :ok
    end

    test "record_failure increments streak; :degraded once threshold reached" do
      assert Health.state("anthropic") == :ok

      # Default threshold is 3 — two failures stay :ok.
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      assert Health.state("anthropic") == :ok

      # Third failure crosses the threshold.
      Health.record_failure("anthropic")
      assert Health.state("anthropic") == :degraded
    end

    test "record_success resets streak to 0 from :degraded" do
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      assert Health.state("anthropic") == :degraded

      Health.record_success("anthropic")
      assert Health.state("anthropic") == :ok
    end

    test "record_success resets mid-streak; subsequent failures start fresh" do
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      Health.record_success("anthropic")
      assert Health.state("anthropic") == :ok

      # Fresh streak — needs 3 more to degrade.
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      assert Health.state("anthropic") == :ok
      Health.record_failure("anthropic")
      assert Health.state("anthropic") == :degraded
    end

    test "successive successes leave lane :ok" do
      for _ <- 1..10, do: Health.record_success("anthropic")
      assert Health.state("anthropic") == :ok
    end

    test "lanes are independent" do
      for _ <- 1..3, do: Health.record_failure("anthropic")
      assert Health.state("anthropic") == :degraded
      assert Health.state("ollama") == :ok
    end
  end

  # ── threshold config override ─────────────────────────────────────────────

  describe "threshold config" do
    test "threshold 3 is the default" do
      Health.record_failure("x")
      Health.record_failure("x")
      assert Health.state("x") == :ok

      Health.record_failure("x")
      assert Health.state("x") == :degraded
    end

    test "threshold is read from app config at call time" do
      Application.put_env(:mimir, :health_threshold, 2)
      on_exit(fn -> Application.delete_env(:mimir, :health_threshold) end)

      Health.record_failure("x")
      assert Health.state("x") == :ok

      Health.record_failure("x")
      assert Health.state("x") == :degraded
    end

    test "threshold 1: first failure degrades immediately" do
      Application.put_env(:mimir, :health_threshold, 1)
      on_exit(fn -> Application.delete_env(:mimir, :health_threshold) end)

      Health.record_failure("x")
      assert Health.state("x") == :degraded
    end
  end

  # ── all/0 ─────────────────────────────────────────────────────────────────

  describe "all/0" do
    test "returns empty map when no lanes have been recorded" do
      assert Health.all() == %{}
    end

    test "returns map of lane → state for every lane seen" do
      for _ <- 1..3, do: Health.record_failure("anthropic")
      Health.record_failure("ollama")

      states = Health.all()
      assert states["anthropic"] == :degraded
      assert states["ollama"] == :ok
    end

    test "includes lane in all/0 even after it recovers" do
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      Health.record_failure("anthropic")
      Health.record_success("anthropic")

      # Lane is still in the map (streak reset to 0, not deleted).
      assert Map.has_key?(Health.all(), "anthropic")
      assert Health.all()["anthropic"] == :ok
    end
  end

  # ── telemetry-driven updates ──────────────────────────────────────────────

  describe "telemetry-driven updates" do
    # We invoke handle_event/4 directly rather than :telemetry.execute/3 to avoid
    # triggering the Ledger handler, which runs synchronously in test mode and
    # needs an Ecto sandbox connection that ExUnit.Case tests don't check out.
    # This tests identical behaviour: lane derivation and success/failure routing.
    # Attachment of the handler to telemetry is covered by the "handler attachment"
    # tests above.
    defp completion_event(model, outcome) do
      Health.handle_event(
        [:example_app, :completion],
        %{latency_ms: 10},
        %{model: model, outcome: outcome},
        nil
      )
    end

    test ":ok outcome calls record_success, resetting a degraded lane" do
      for _ <- 1..3, do: Health.record_failure("anthropic")
      assert Health.state("anthropic") == :degraded

      completion_event("anthropic:claude-sonnet-4-6", :ok)

      assert Health.state("anthropic") == :ok
    end

    test ":error outcome calls record_failure; 3 events degrade the lane" do
      for _ <- 1..3, do: completion_event("anthropic:claude-sonnet-4-6", :error)

      assert Health.state("anthropic") == :degraded
    end

    test "provider prefix is derived from model string (split on first ':')" do
      completion_event("ollama:nemotron-super-70b", :ok)

      # "ollama" lane was touched; "anthropic" is still unknown → :ok
      assert Health.state("ollama") == :ok
      assert Health.state("anthropic") == :ok
    end

    test "interleaved successes and failures across two lanes" do
      # anthropic gets 3 failures → degraded
      for _ <- 1..3, do: completion_event("anthropic:sonnet", :error)

      # ollama gets 2 failures → still :ok
      for _ <- 1..2, do: completion_event("ollama:nemotron", :error)

      assert Health.state("anthropic") == :degraded
      assert Health.state("ollama") == :ok

      # anthropic recovers
      completion_event("anthropic:sonnet", :ok)

      assert Health.state("anthropic") == :ok
      assert Health.state("ollama") == :ok
    end
  end

  # ── configurable completion event ─────────────────────────────────────────

  describe "configurable completion event" do
    test "attach/0 binds the configured completion event" do
      Application.put_env(:mimir, :completion_event, [:custom, :done])
      on_exit(fn -> Application.delete_env(:mimir, :completion_event) end)

      :ok = Mimir.Health.attach()
      on_exit(fn -> :telemetry.detach("mimir-router-health") end)

      :telemetry.execute([:custom, :done], %{}, %{model: "anthropic:x", outcome: :error})
      :telemetry.execute([:custom, :done], %{}, %{model: "anthropic:x", outcome: :error})
      :telemetry.execute([:custom, :done], %{}, %{model: "anthropic:x", outcome: :error})
      assert Mimir.Health.state("anthropic") == :degraded
    end
  end
end
