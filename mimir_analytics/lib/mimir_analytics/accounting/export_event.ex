defmodule MimirAnalytics.Accounting.ExportEvent do
  @moduledoc "Closed financial-or-audit accounting export boundary."
  alias MimirAnalytics.Accounting.{AuditEvent, Error, Event, Source}
  alias MimirAnalytics.Mapper
  @type t :: Event.t() | AuditEvent.t()
  @spec new(Mapper.source_map(), Source.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{"kind" => kind} = wire, source) when kind in ["routing", "lifecycle"],
    do: AuditEvent.new(wire, source)

  def new(wire, source), do: Event.new(wire, source)
  @spec to_wire(t()) :: Mapper.source_map()
  def to_wire(%Event{} = event), do: Event.to_wire(event)
  def to_wire(%AuditEvent{} = event), do: AuditEvent.to_wire(event)
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%Event{} = event), do: Event.fingerprint(event)
  def fingerprint(%AuditEvent{} = event), do: AuditEvent.fingerprint(event)
end
