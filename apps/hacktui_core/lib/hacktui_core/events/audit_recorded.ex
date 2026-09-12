defmodule HacktuiCore.Events.AuditRecorded do
  @moduledoc """
  Domain event emitted when an auditable action is recorded.
  """

  @enforce_keys [:event_id, :audit_id, :actor, :action, :occurred_at, :result, :subject]
  defstruct [
    :event_id,
    :audit_id,
    :actor,
    :action,
    :occurred_at,
    :result,
    :subject,
    :source,
    :fingerprint,
    :marking,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          audit_id: String.t(),
          actor: HacktuiCore.ActorRef.t(),
          action: atom(),
          occurred_at: DateTime.t(),
          result: atom(),
          subject: String.t(),
          source: String.t() | nil,
          fingerprint: String.t() | nil,
          marking: HacktuiCore.Marking.t() | nil,
          metadata: map()
        }
end
