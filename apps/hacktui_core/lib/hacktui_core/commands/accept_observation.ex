defmodule HacktuiCore.Commands.AcceptObservation do
  @moduledoc """
  Command contract for accepting a normalized observation into the hub.
  """

  @enforce_keys [
    :observation_id,
    :envelope_version,
    :source,
    :kind,
    :summary,
    :raw_message,
    :payload,
    :metadata,
    :severity,
    :confidence,
    :received_at,
    :actor
  ]
  defstruct [
    :observation_id,
    :fingerprint,
    :raw_message_sha256,
    :marking,
    :envelope_version,
    :source,
    :kind,
    :summary,
    :raw_message,
    :payload,
    :observed_at,
    :metadata,
    :severity,
    :confidence,
    :received_at,
    :actor
  ]

  @type t :: %__MODULE__{
          observation_id: String.t(),
          fingerprint: String.t() | nil,
          raw_message_sha256: String.t() | nil,
          marking: HacktuiCore.Marking.t() | nil,
          envelope_version: pos_integer(),
          source: atom(),
          kind: atom() | String.t(),
          summary: String.t(),
          raw_message: String.t(),
          payload: map(),
          observed_at: DateTime.t() | nil,
          metadata: map(),
          severity: atom() | String.t(),
          confidence: number(),
          received_at: DateTime.t(),
          actor: String.t()
        }

  @spec from_envelope(struct() | map()) :: t()
  def from_envelope(%_{} = envelope) do
    envelope
    |> Map.from_struct()
    |> from_envelope()
  end

  def from_envelope(envelope) when is_map(envelope) do
    payload = fetch!(envelope, :payload)
    received_at = fetch!(envelope, :received_at)

    observation_id =
      Map.get(envelope, :observation_id, Map.get(envelope, "observation_id")) ||
        deterministic_observation_id(envelope)

    fingerprint =
      Map.get(envelope, :fingerprint, Map.get(envelope, "fingerprint")) ||
        deterministic_fingerprint(envelope)

    struct!(__MODULE__, %{
      observation_id: observation_id,
      fingerprint: fingerprint,
      raw_message_sha256: Map.get(envelope, :raw_message_sha256),
      marking: Map.get(envelope, :marking),
      envelope_version: Map.get(envelope, :envelope_version, 1),
      source: fetch!(envelope, :source),
      kind: fetch!(envelope, :kind),
      payload: payload,
      metadata: Map.get(envelope, :metadata, %{}),
      observed_at: Map.get(envelope, :observed_at, received_at),
      received_at: received_at,
      actor: Map.get(envelope, :actor, %{type: :system, id: "replay-runner"})
    })
  end

  defp deterministic_observation_id(attrs) do
    "replay-" <> binary_part(deterministic_fingerprint(attrs), 0, 16)
  end

  defp deterministic_fingerprint(attrs) do
    metadata = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))

    sequence =
      Map.get(metadata, :sequence) ||
        Map.get(metadata, "sequence") ||
        0

    payload = Map.get(attrs, :payload, Map.get(attrs, "payload", %{}))
    source = Map.get(attrs, :source, :unknown)
    received_at = Map.get(attrs, :received_at)

    :erlang.term_to_binary({source, received_at, sequence, payload})
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end
end
