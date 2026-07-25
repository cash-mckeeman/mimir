defmodule Mimir.CloudEvent.Types do
  @moduledoc """
  The registered CloudEvents `type` taxonomy for the mimir ecosystem, namespaced
  under `ai.bizinsights.mimir.*` (reverse-DNS of the owned domain bizinsights.ai).

  These are helpers, not a closed union: a CloudEvents `type` is an open string,
  so a broker or consumer never rejects an unknown/newer family. Centralizing the
  strings here means the namespace is written in exactly one place and producers
  never hand-assemble a `type`.
  """
  alias Mimir.Event

  @namespace "ai.bizinsights.mimir"

  @doc "The `type` for a lifecycle `Mimir.Event`: `ai.bizinsights.mimir.<domain>.<type>`."
  @spec for_event(Event.t()) :: String.t()
  def for_event(%Event{domain: domain, type: type}), do: "#{@namespace}.#{domain}.#{type}"

  @doc """
  The routing-decision record `type`.

  Distinct from the older bare `"routing_decision"` string `Mimir.RouteLog`
  stamps on its turn-event entry: that one names the entry *inside* a request
  log, this one names the CloudEvent wrapping the same record. A wrapped
  decision carries both — this `type` on the envelope, `"routing_decision"`
  within `data`. Neither supersedes the other.
  """
  @spec routing_decision() :: String.t()
  def routing_decision, do: "#{@namespace}.routing.decision"

  @doc "The gateway ledger/metering completion `type`."
  @spec ledger_completion() :: String.t()
  def ledger_completion, do: "#{@namespace}.ledger.completion"

  @doc "The eval-outcome record `type`."
  @spec eval_outcome() :: String.t()
  def eval_outcome, do: "#{@namespace}.eval.outcome"

  @doc """
  A memory-provenance `type` for `event`
  (proposed/recalled/accepted/corrected/promoted/demoted/archived).

  **Provisional.** Unlike the other families here, no producer implements this
  vocabulary yet — the seven states are a proposal, not a description of shipped
  code, and they may be renamed once a real memory producer names its own. Treat
  this helper as unstable in a way the rest of the module is not.
  """
  @spec memory(atom() | String.t()) :: String.t()
  def memory(event), do: "#{@namespace}.memory.#{event}"

  @doc "The namespace prefix every taxonomy `type` shares."
  @spec namespace() :: String.t()
  def namespace, do: @namespace
end
