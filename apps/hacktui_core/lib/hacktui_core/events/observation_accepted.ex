defmodule HacktuiCore.Events.ObservationAccepted do
  @moduledoc """
  Domain event emitted when an observation is accepted by the ingest boundary.

  Carries the observation's identity (`fingerprint`), the sha256 of its raw bytes
  (`raw_message_sha256` -- never the bytes) and its classification marking (slice 40).
  """

  @enforce_keys [:event_id, :observation_id, :source, :accepted_at, :actor]
  defstruct [
    :event_id,
    :observation_id,
    :source,
    :kind,
    :payload,
    :metadata,
    :fingerprint,
    :raw_message_sha256,
    :marking,
    :accepted_at,
    :actor
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          observation_id: String.t(),
          source: atom(),
          kind: String.t() | atom() | nil,
          payload: map() | nil,
          metadata: map() | nil,
          fingerprint: String.t() | nil,
          raw_message_sha256: String.t() | nil,
          marking: HacktuiCore.Marking.t() | nil,
          accepted_at: DateTime.t(),
          actor: HacktuiCore.ActorRef.t()
        }
end
