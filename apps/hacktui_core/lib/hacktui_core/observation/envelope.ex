defmodule HacktuiCore.Observation.Envelope do
  @moduledoc """
  Transport-level observation envelope for telemetry and ingestion payloads.

  This is intentionally separate from `HacktuiCore.Events.*`, which model
  domain events and should remain unchanged.
  """

  # Envelope version 2 (slice 40) adds the three fields that used to die at the
  # command -> event boundary: the collector's identity for the observation, the sha256 of
  # the raw bytes (the evidence commitment; the bytes themselves stay out of the event), and
  # the classification marking. All three are optional here: an absent fingerprint falls
  # back to a content hash, an absent digest is computed from `raw_message`, and an absent
  # marking inherits the enclave marking at ingest.
  @envelope_version 2

  @enforce_keys [:source, :kind, :payload]
  defstruct [
    :source,
    :kind,
    :payload,
    :received_at,
    :fingerprint,
    :raw_message_sha256,
    :marking,
    envelope_version: @envelope_version,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          source: String.t() | atom(),
          kind: String.t() | atom(),
          payload: map(),
          received_at: DateTime.t() | nil,
          fingerprint: String.t() | nil,
          raw_message_sha256: String.t() | nil,
          marking: HacktuiCore.Marking.t() | nil,
          envelope_version: pos_integer(),
          metadata: map()
        }

  @doc "The envelope version this release emits and replays."
  @spec version() :: pos_integer()
  def version, do: @envelope_version

  @spec new(String.t() | atom(), String.t() | atom(), map()) :: t()
  def new(source, kind, payload) when is_map(payload) do
    %__MODULE__{
      source: source,
      kind: kind,
      payload: payload,
      received_at: DateTime.utc_now(),
      envelope_version: @envelope_version,
      metadata: %{}
    }
  end
end
