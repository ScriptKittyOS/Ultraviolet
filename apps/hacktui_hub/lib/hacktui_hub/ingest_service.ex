defmodule HacktuiHub.IngestService do
  @moduledoc """
  Hub-facing service wrapper around the pure ingest command handler.
  Fixed to route live telemetry to the GenServer IngestBuffer safely, 
  preventing fatal :persistent_term memory allocator crashes.
  """

  alias HacktuiCore.CommandHandlers.Ingest
  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.ObservationAccepted
  alias HacktuiCore.Marking
  alias HacktuiHub.ThreatIntel.Enricher
  alias HacktuiHub.IngestBuffer

  @spec accept_observation(AcceptObservation.t(), keyword()) :: term()
  def accept_observation(%AcceptObservation{} = command, opts) do
    command = command |> inherit_marking() |> enrich_command()
    opts = ingest_opts(command, opts)

    case Ingest.handle(command, opts) do
      {:ok, %ObservationAccepted{} = accepted} ->
        accepted = enrich_accepted(accepted, command)

        try do
          IngestBuffer.insert(accepted)
        catch
          :exit, _ -> :ok
        end

        {:ok, accepted}

      other ->
        other
    end
  end

  @spec recent_observations() :: [ObservationAccepted.t()]
  def recent_observations do
    try do
      IngestBuffer.get_recent()
    catch
      :exit, _ -> []
    end
  end

  @spec reset_recent_observations() :: :ok
  def reset_recent_observations do
    try do
      IngestBuffer.clear()
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # Slice 40: an observation that arrives unmarked inherits the enclave marking; one that
  # arrives marked keeps its marking, normalised. This is the ingest-side inheritance, so
  # the event's marking is never nil; the store's `MarkingField.for_write/1` covers rows
  # that have no observation (a manually created alert). A malformed marking raises: it
  # must not be stored as if it were one.
  defp inherit_marking(%AcceptObservation{marking: nil} = command),
    do: %AcceptObservation{command | marking: Marking.enclave()}

  defp inherit_marking(%AcceptObservation{marking: marking} = command),
    do: %AcceptObservation{command | marking: Marking.normalize!(marking)}

  defp ingest_opts(%AcceptObservation{} = command, opts) do
    now = command.received_at || command.observed_at || DateTime.utc_now()

    opts
    |> Keyword.put_new(:event_id, "ingest-#{command.observation_id}")
    |> Keyword.put_new(:accepted_at, now)
  end

  defp enrich_accepted(%ObservationAccepted{} = accepted, %AcceptObservation{} = command) do
    %ObservationAccepted{
      accepted
      | kind: command.kind,
        payload: command.payload,
        metadata: command.metadata
    }
  end

  defp enrich_command(%AcceptObservation{} = command) do
    # Create a safe, compliant struct for the Enricher to avoid compiler warnings
    dummy_obs = %ObservationAccepted{
      event_id: "enrich-#{command.observation_id}",
      observation_id: command.observation_id,
      source: command.source || "unknown",
      kind: command.kind || "unknown",
      payload: command.payload || %{},
      metadata: command.metadata || %{},
      accepted_at: command.received_at || command.observed_at || DateTime.utc_now(),
      actor: command.actor || "system"
    }

    enriched_obs = Enricher.enrich(dummy_obs)
    apply_enriched_command(enriched_obs, command)
  rescue
    _ -> command
  end

  defp apply_enriched_command(%ObservationAccepted{} = enriched, %AcceptObservation{} = command) do
    metadata = Map.get(enriched, :metadata, %{}) || %{}

    severity =
      metadata
      |> Map.get(:threat_context, %{})
      |> case do
        m when is_map(m) -> Map.get(m, :severity)
        _ -> nil
      end
      |> case do
        nil -> Map.get(command, :severity)
        threat_severity -> threat_severity
      end

    %AcceptObservation{command | metadata: metadata, severity: severity}
  end

  defp apply_enriched_command(_, %AcceptObservation{} = command), do: command
end
