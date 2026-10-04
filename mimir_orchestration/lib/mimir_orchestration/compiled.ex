defmodule MimirOrchestration.Compiled do
  @moduledoc "Output of a clean compile: lowered atom-keyed steps + warnings. Targets are opaque host refs."
  alias MimirWorkflows.Diagnostic

  @type step :: %{
          id: String.t(),
          kind: String.t(),
          target: term(),
          input_template: term(),
          descriptor: map(),
          depends_on: [String.t()],
          runtime: atom() | nil
        }
  @type t :: %__MODULE__{
          name: String.t(),
          version: integer(),
          params: [String.t()],
          steps: [step()],
          warnings: [Diagnostic.t()]
        }
  @enforce_keys [:name, :version, :params, :steps]
  defstruct [:name, :version, :params, :steps, warnings: []]
end
