defmodule MimirOrchestration.AgentRunner.RMA.RunOutcome do
  @moduledoc false
  @enforce_keys [:return, :session_result, :authority]
  defstruct [:return, :session_result, :authority]

  @type session_return :: {:ok, ReqManagedAgents.SessionResult.t()} | {:error, term()}
  @type t :: %__MODULE__{
          return: session_return(),
          session_result: ReqManagedAgents.SessionResult.t() | nil,
          authority: :session_result | :partial_result | :unknown
        }

  @spec new(session_return(), ReqManagedAgents.SessionResult.t() | nil) ::
          {:ok, t()} | {:error, {:invalid_run_outcome, :return | :session_result}}
  def new(return, notified) do
    cond do
      not valid_return?(return) ->
        {:error, {:invalid_run_outcome, :return}}

      not (is_nil(notified) or valid_result?(notified)) ->
        {:error, {:invalid_run_outcome, :session_result}}

      true ->
        {:ok, select(return, notified)}
    end
  end

  defp valid_return?({:ok, result}), do: valid_result?(result)
  defp valid_return?({:error, _reason}), do: true
  defp valid_return?(_return), do: false

  if Code.ensure_loaded?(ReqManagedAgents.SessionResult) do
    defp valid_result?(%ReqManagedAgents.SessionResult{}), do: true
    defp valid_result?(_result), do: false

    defp select({:ok, result} = return, _notified),
      do: %__MODULE__{return: return, session_result: result, authority: :session_result}

    defp select({:error, _reason} = return, notified), do: failure(return, notified)
  else
    defp valid_result?(_result), do: false
    defp select(return, notified), do: failure(return, notified)
  end

  defp failure(return, notified),
    do: %__MODULE__{
      return: return,
      session_result: notified,
      authority: if(is_nil(notified), do: :unknown, else: :partial_result)
    }
end
