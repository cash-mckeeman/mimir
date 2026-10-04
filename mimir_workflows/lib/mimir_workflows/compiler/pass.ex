defmodule MimirWorkflows.Compiler.Pass do
  @moduledoc """
  Behaviour for host-supplied compile passes.

  Policy, budget, kind-vocabulary, allowlists — anything domain-shaped —
  is a host concern delivered through this behaviour. A pass receives the
  best-effort parsed `%Spec{}` (it may carry earlier diagnostics'
  omissions, e.g. steps with `id: nil`) plus an opaque host context, and
  returns diagnostics. Passes must not raise on malformed specs — skip
  what cannot be checked; the schema pass already reported it.
  """

  alias MimirWorkflows.{Diagnostic, Spec}

  @callback check(spec :: Spec.t(), ctx :: term()) :: [Diagnostic.t()]
end
