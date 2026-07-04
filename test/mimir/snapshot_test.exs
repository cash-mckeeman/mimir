defmodule Mimir.SnapshotTest do
  # async: false — assemble/1 reads app env (:mimir, :pricing).
  use ExUnit.Case, async: false

  alias Mimir.Snapshot

  @pricing %{
    "anthropic:sonnet" => %{input: 3_000_000, output: 15_000_000},
    "ollama:nemotron" => %{input: 0, output: 0}
  }

  setup do
    prev_pricing = Application.get_env(:mimir, :pricing)
    Application.put_env(:mimir, :pricing, @pricing)

    on_exit(fn ->
      if prev_pricing != nil,
        do: Application.put_env(:mimir, :pricing, prev_pricing),
        else: Application.delete_env(:mimir, :pricing)
    end)

    :ok
  end

  # ── struct definition (pure, no assemble) ─────────────────────────────────

  test "Snapshot struct has expected default fields" do
    snap = %Snapshot{pricing: %{}, snapshot_at: ~U[2026-07-04 00:00:00Z]}
    assert snap.health == %{}
    assert snap.parent_remaining == :unlimited
    assert snap.rpm_headroom == :unlimited
  end

  # ── assemble/1 ────────────────────────────────────────────────────────────

  describe "assemble/1" do
    test "no options → parent_remaining :unlimited" do
      snap = Snapshot.assemble([])

      assert %Snapshot{} = snap
      assert snap.pricing == @pricing
      assert snap.parent_remaining == :unlimited
      assert snap.rpm_headroom == :unlimited
      assert %DateTime{} = snap.snapshot_at
    end

    test "no :parent_remaining option → :unlimited" do
      snap = Snapshot.assemble([])
      assert snap.parent_remaining == :unlimited
    end

    test ":parent_remaining option is passed through" do
      snap = Snapshot.assemble(parent_remaining: 42_000)
      assert snap.parent_remaining == 42_000
    end

    test "explicit :health option reflects the given lane map" do
      snap = Snapshot.assemble(health: %{"anthropic" => :degraded})
      assert snap.health["anthropic"] == :degraded
    end

    test "snapshot_at is approximately now" do
      before = DateTime.utc_now()
      snap = Snapshot.assemble([])
      after_now = DateTime.utc_now()

      assert DateTime.compare(snap.snapshot_at, before) in [:gt, :eq]
      assert DateTime.compare(snap.snapshot_at, after_now) in [:lt, :eq]
    end

    test "rpm_headroom is :unlimited by default" do
      snap = Snapshot.assemble([])
      assert snap.rpm_headroom == :unlimited
    end

    test "pricing comes from app config" do
      custom = %{"openai:gpt-4o" => %{input: 5_000_000, output: 15_000_000}}
      Application.put_env(:mimir, :pricing, custom)

      snap = Snapshot.assemble([])
      assert snap.pricing == custom
    end

    test "pricing defaults to empty map if config absent" do
      Application.delete_env(:mimir, :pricing)

      snap = Snapshot.assemble([])
      assert snap.pricing == %{}
    end

    test "explicit :pricing option overrides app config" do
      explicit = %{"custom:model" => %{input: 1, output: 2}}
      snap = Snapshot.assemble(pricing: explicit)
      assert snap.pricing == explicit
    end
  end
end
