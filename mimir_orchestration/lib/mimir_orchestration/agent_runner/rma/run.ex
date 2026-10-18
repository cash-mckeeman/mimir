defmodule MimirOrchestration.AgentRunner.RMA.Run do
  @moduledoc false
  alias MimirOrchestration.AgentRunner.RMA.RunOutcome

  @spec capture(module(), keyword()) :: RunOutcome.t()
  def capture(provider, opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn -> execute(provider, opts) end,
          shutdown: :brutal_kill
        )

      case Task.yield(task, :infinity) do
        {:ok, outcome} -> outcome
        {:exit, reason} -> outcome({:error, {:run_worker_exit, reason}}, nil)
      end
    after
      Supervisor.stop(supervisor, :normal, :infinity)
    end
  end

  if Code.ensure_loaded?(ReqManagedAgents.Session) do
    alias ReqManagedAgents.{Session, SessionResult}

    defp execute(provider, opts) do
      return = Session.run(provider, Keyword.put(opts, :notify, self()))

      notified =
        receive do
          {:managed_agents_session, %SessionResult{} = result} -> result
        after
          0 -> nil
        end

      outcome(return, notified)
    end
  else
    defp execute(_provider, _opts),
      do: outcome({:error, {:missing_dependency, :req_managed_agents}}, nil)
  end

  defp outcome(return, notified) do
    {:ok, outcome} = RunOutcome.new(return, notified)
    outcome
  end
end
