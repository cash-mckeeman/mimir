defmodule MimirOrchestration.Executor.Payload do
  @moduledoc """
  Everything an executor needs to run one workflow, as plain data: no functions,
  pids, references or ports at any depth. `new/2` refuses a payload that breaks the
  rule, so no executor ever receives one.

  Callables are MFAs, `{module, function, extra_args}`, invoked as
  `apply(module, function, [data | extra_args])`, where `data` is what the call is
  about and `extra_args` carries the caller's own data.

  Plain data is not a credential policy. The router's options travel as given, so
  a bearer token passed to `Mimir.RouterClient.HTTP` is in the payload; an executor
  that persists payloads must not store such a value raw.
  """
  alias MimirOrchestration.Executor.Serialisable
  alias MimirOrchestration.Runner

  @enforce_keys [:steps, :workflow_id, :run]
  defstruct [
    :steps,
    :workflow_id,
    :run,
    router: nil,
    params: %{},
    max_concurrency: 4,
    step_timeout: 120_000,
    halt: :after_phase
  ]

  @type mfa_ref :: {module(), atom(), [term()]}
  @type step :: Runner.step()
  @type t :: %__MODULE__{
          steps: [step()],
          workflow_id: String.t(),
          run: mfa_ref(),
          router: {module(), keyword()} | nil,
          params: map(),
          max_concurrency: pos_integer(),
          step_timeout: timeout(),
          halt: :immediate | :after_phase
        }

  @doc """
  Builds the payload from `Runner.run/2`'s steps and options, then checks it.

  Options: `:run` (required), `:router`, `:workflow_id` (default a random `"wf-…"`),
  `:params` (default `%{}`), `:max_concurrency` (4), `:step_timeout` (120 000 ms;
  `:infinity` allowed), `:halt` (`:after_phase`).
  """
  @spec new([step()], keyword()) ::
          {:ok, t()} | {:error, {:not_serialisable, [term()], Serialisable.kind()}}
  def new(steps, opts) do
    payload = %__MODULE__{
      steps: steps,
      workflow_id: Keyword.get_lazy(opts, :workflow_id, &random_workflow_id/0),
      run: Keyword.fetch!(opts, :run),
      router: Keyword.get(opts, :router),
      params: Keyword.get(opts, :params, %{}),
      max_concurrency: Keyword.get(opts, :max_concurrency, 4),
      step_timeout: Keyword.get(opts, :step_timeout, 120_000),
      halt: Keyword.get(opts, :halt, :after_phase)
    }

    with :ok <- Serialisable.check(payload), do: {:ok, payload}
  end

  defp random_workflow_id, do: "wf-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
