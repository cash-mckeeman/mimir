defmodule Integration.ExecutionBindingLocal do
  @moduledoc false
  @behaviour ReqManagedAgents.Provider
  alias ReqManagedAgents.Providers.Local

  @impl true
  def open(opts, subscriber) do
    send(opts[:spec][:test_owner], {:provider_open, opts[:model_config]})
    Local.open(opts, subscriber)
  end

  @impl true
  defdelegate supports_runtime_model?(), to: Local
  @impl true
  defdelegate data_plane(), to: Local
  @impl true
  defdelegate mode(), to: Local
  @impl true
  defdelegate provision(spec, opts), to: Local
  @impl true
  defdelegate teardown(handle, opts), to: Local
  @impl true
  defdelegate session_id(conn), to: Local
  @impl true
  defdelegate ref(conn), to: Local
  @impl true
  defdelegate consumer(conn), to: Local
  @impl true
  defdelegate resumed?(conn), to: Local
  @impl true
  defdelegate transcript(conn), to: Local
  @impl true
  defdelegate kickoff_input(opts), to: Local
  @impl true
  defdelegate user_input(text), to: Local
  @impl true
  defdelegate resume_input(tool_uses, results), to: Local
  @impl true
  defdelegate poll_turn(conn, input), to: Local
  @impl true
  defdelegate normalize(events), to: Local
  @impl true
  defdelegate text_delta(event), to: Local
end
