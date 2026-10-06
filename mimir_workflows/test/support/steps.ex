defmodule MimirWorkflows.TestSteps.Echo do
  @moduledoc false
  @behaviour MimirWorkflows.Step
  @impl true
  def run(params, upstream), do: {:ok, %{params: params, upstream: upstream}}
end

defmodule MimirWorkflows.TestSteps.Fail do
  @moduledoc false
  @behaviour MimirWorkflows.Step
  @impl true
  def run(_params, _upstream), do: {:error, :boom}
end

defmodule MimirWorkflows.TestSteps.Crash do
  @moduledoc false
  @behaviour MimirWorkflows.Step
  @impl true
  def run(_params, _upstream), do: raise("kaboom")
end

defmodule MimirWorkflows.TestSteps.SlowNotify do
  @moduledoc false
  @behaviour MimirWorkflows.Step
  @impl true
  def run(%{owner: owner, ms: ms, id: id}, _upstream) do
    Process.sleep(ms)
    send(owner, {:finished, id})
    {:ok, %{}}
  end
end
