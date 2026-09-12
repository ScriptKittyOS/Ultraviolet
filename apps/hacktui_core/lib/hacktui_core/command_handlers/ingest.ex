defmodule HacktuiCore.CommandHandlers.Ingest do
  @moduledoc """
  Pure command handling for the ingest boundary.
  """

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.ObservationAccepted
  alias HacktuiCore.Text

  @spec handle(AcceptObservation.t(), keyword()) :: {:ok, ObservationAccepted.t()}
  def handle(%AcceptObservation{} = command, opts) do
    {:ok,
     %ObservationAccepted{
       event_id: Keyword.fetch!(opts, :event_id),
       observation_id: command.observation_id,
       source: command.source,
       fingerprint: command.fingerprint,
       raw_message_sha256: raw_message_sha256(command),
       marking: command.marking,
       accepted_at: Keyword.fetch!(opts, :accepted_at),
       actor: command.actor
     }}
  end

  # The evidence commitment: the full digest of the bytes as received. A collector may
  # supply it (when it digested before sanitising); otherwise it is taken over the raw
  # message the command carries. The raw bytes themselves do not enter the event.
  defp raw_message_sha256(%AcceptObservation{raw_message_sha256: digest})
       when is_binary(digest),
       do: digest

  defp raw_message_sha256(%AcceptObservation{raw_message: raw}) when is_binary(raw),
    do: Text.original_sha256(raw)

  defp raw_message_sha256(_command), do: nil
end
