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
