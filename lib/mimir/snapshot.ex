defmodule Mimir.Snapshot do
  @moduledoc """
  A point-in-time view of the operational state the oracle ranks against.
  Assembled from explicit inputs — the embedder wires its own health, pricing,
  and budget sources; the oracle only ever sees this struct. Staleness affects
  optimality, never safety: enforcement happens where budgets are enforced,
  not here.

  `assemble/1` with no options is the degenerate snapshot: all lanes healthy,
  config pricing, unlimited budget.
  """

  @enforce_keys [:pricing, :snapshot_at]
  defstruct [
    :pricing,
    :snapshot_at,
    health: %{},
    parent_remaining: :unlimited
  ]

  @type rates :: %{input: non_neg_integer(), output: non_neg_integer()}
  @type t :: %__MODULE__{
          pricing: %{optional(String.t()) => rates()},
          snapshot_at: DateTime.t(),
          health: %{optional(String.t()) => :ok | :degraded},
          parent_remaining: :unlimited | integer()
        }

  @doc """
  Assemble a snapshot from explicit inputs.

  - `:pricing` — model → `%{input:, output:}` rate map; defaults to
    `Application.get_env(:mimir, :pricing, %{})`.
  - `:health` — lane → `:ok | :degraded` (e.g. `Mimir.Health.all/0`); default `%{}`.
  - `:parent_remaining` — remaining caller budget in microdollars, or `:unlimited`.
  - `:snapshot_at` — defaults to `DateTime.utc_now()`.
  """
  @spec assemble(keyword()) :: t()
  def assemble(opts \\ []) do
    %__MODULE__{
      pricing: Keyword.get(opts, :pricing, Application.get_env(:mimir, :pricing, %{})),
      health: Keyword.get(opts, :health, %{}),
      parent_remaining: Keyword.get(opts, :parent_remaining, :unlimited),
      snapshot_at: Keyword.get(opts, :snapshot_at, DateTime.utc_now())
    }
  end
end
