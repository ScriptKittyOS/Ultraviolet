defmodule HacktuiHub.Replay.Runner do
  @moduledoc false

  alias HacktuiCore.Commands.AcceptObservation
  alias HacktuiCore.Events.ObservationAccepted
  alias HacktuiCore.Observation.Envelope
  alias HacktuiHub.DetectionService
  alias HacktuiHub.PurpleService
  alias HacktuiHub.Replay.Loader

  @spec run_fixture!(Path.t(), keyword()) :: [term()]
  def run_fixture!(path, opts \\ []) do
    path
    |> fixture_path()
    |> Loader.load_fixture!()
    |> run_envelopes!(opts)
  end

  @spec run_envelopes!([Envelope.t()], keyword()) :: [term()]
  def run_envelopes!(envelopes, opts \\ []) when is_list(envelopes) do
    now = DateTime.utc_now()

    envelopes
    |> Enum.with_index(1)
    |> Enum.map(fn {envelope, generated_sequence} ->
      envelope
      |> maybe_put_sequence(generated_sequence)
      |> maybe_put_generated_sequence(generated_sequence)
      |> maybe_put_ingested_at(now)
      |> accept_envelope!(opts)
    end)
  end

  @spec derive_alerts!([ObservationAccepted.t()], keyword()) :: [term()]
  def derive_alerts!(accepted_observations, opts \\ []) when is_list(accepted_observations) do
    Enum.map(accepted_observations, &derive_alert!(&1, opts))
  end

  @spec derive_exercises!([ObservationAccepted.t()]) :: [term()]
  def derive_exercises!(accepted_observations) when is_list(accepted_observations) do
    Enum.map(accepted_observations, fn accepted ->
      {:ok, exercise} = PurpleService.derive_exercise(accepted)
      exercise
    end)
  end

  defp accept_envelope!(%Envelope{} = envelope, opts) do
    command =
      %{
        observation_id:
          metadata_value(envelope.metadata, :observation_id) || replay_observation_id(envelope),
        source: envelope.source,
        kind: envelope.kind,
        payload: envelope.payload || %{},
        metadata: envelope.metadata || %{},
        actor: Map.get(envelope.metadata || %{}, :actor, "replay_runner"),
        envelope_version: envelope.envelope_version,
        raw_message_sha256: envelope.raw_message_sha256,
        marking: envelope.marking,
        received_at: envelope.received_at
      }
      |> ensure_observation_contract(envelope)
      |> then(&struct!(AcceptObservation, &1))

    command
    |> HacktuiHub.Runtime.accept_observation(acceptance_opts(envelope, opts))
    |> unwrap_acceptance!(envelope)
  end

  defp accept_envelope!(other, _opts) do
    raise ArgumentError, "expected replay loader to return envelopes, got: #{inspect(other)}"
  end

  defp ensure_observation_contract(command, %Envelope{} = envelope) when is_map(command) do
    payload = command.payload || %{}
    summary = payload_value(payload, :summary) || fallback_summary(envelope)

    fingerprint =
      envelope.fingerprint ||
        payload_value(payload, :fingerprint) ||
        metadata_value(envelope.metadata, :fingerprint) ||
        command.observation_id

    raw_message = payload_value(payload, :raw_message) || summary
    severity = normalize_severity(payload_value(payload, :severity) || :low)
    confidence = normalize_confidence(payload_value(payload, :confidence) || 0.6)

    Map.merge(command, %{
      summary: summary,
      fingerprint: fingerprint,
      raw_message: raw_message,
      severity: severity,
      confidence: confidence,
      payload:
        payload
        |> Map.put_new(:summary, summary)
        |> Map.put_new(:fingerprint, fingerprint)
        |> Map.put_new(:raw_message, raw_message)
        |> Map.put_new(:severity, severity)
        |> Map.put_new(:confidence, confidence)
    })
  end

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp metadata_value(metadata, key) do
    metadata = metadata || %{}
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp fallback_summary(%Envelope{} = envelope) do
    payload = envelope.payload || %{}

    payload_value(payload, :summary) ||
      payload_value(payload, :message) ||
      payload_value(payload, :raw_message) ||
      envelope.kind ||
      envelope.source ||
      "replay observation"
  end

  defp normalize_severity(severity) when severity in [:low, :medium, :high, :critical],
    do: severity

  defp normalize_severity(severity) when is_binary(severity) do
    severity
    |> String.downcase()
    |> case do
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "critical" -> :critical
      _ -> :low
    end
  end

  defp normalize_severity(_), do: :low

  defp normalize_confidence(confidence) when is_float(confidence), do: confidence
  defp normalize_confidence(confidence) when is_integer(confidence), do: confidence / 1

  defp normalize_confidence(confidence) when is_binary(confidence) do
    case Float.parse(confidence) do
      {value, _} -> value
      :error -> 0.6
    end
  end

  defp normalize_confidence(_), do: 0.6

  defp unwrap_acceptance!({:ok, %{observation: %ObservationAccepted{} = accepted}}, _envelope),
    do: accepted

  defp unwrap_acceptance!(other, %Envelope{} = envelope) do
    raise ArgumentError,
          "unexpected replay acceptance result for #{inspect(envelope.kind)}: #{inspect(other)}"
  end

  defp derive_alert!(%ObservationAccepted{} = accepted, opts) do
    accepted
    |> DetectionService.derive_alert(derivation_opts(accepted, opts))
    |> unwrap_derivation!(accepted)
  end

  defp derive_alert!(other, _opts) do
    raise ArgumentError, "expected accepted observations for derivation, got: #{inspect(other)}"
  end

  defp unwrap_derivation!({:ok, derived_alert, derived_event}, _accepted),
    do: {derived_alert, derived_event}

  defp unwrap_derivation!(derived, _accepted), do: derived

  defp acceptance_opts(%Envelope{} = envelope, opts) do
    opts
    |> Keyword.put_new(:event_id, replay_event_id(envelope))
    |> Keyword.put_new(:accepted_at, envelope.received_at)
  end

  defp derivation_opts(%ObservationAccepted{} = accepted, opts) do
    opts
    |> Keyword.put_new(:event_id, "derived-#{accepted.event_id}")
    |> Keyword.put_new(:occurred_at, accepted.accepted_at)
  end

  defp envelope_sequence(%Envelope{} = envelope) do
    Map.get(envelope.metadata, "sequence") ||
      Map.get(envelope.metadata, :sequence)
  end

  defp replay_event_id(%Envelope{} = envelope) do
    sequence = envelope_sequence(envelope) || "unknown"

    "replay-#{envelope.source}-#{envelope.kind}-#{sequence}"
  end

  defp replay_observation_id(%Envelope{} = envelope) do
    metadata_value(envelope.metadata, :event_id) || replay_event_id(envelope)
  end

  defp fixture_path(path) do
    cond do
      Path.type(path) == :absolute ->
        path

      String.contains?(path, "/") ->
        path

      true ->
        file = if String.ends_with?(path, ".jsonl"), do: path, else: path <> ".jsonl"

        candidates = [
          Path.expand(file),
          Path.expand(Path.join(["fixtures", "replay", file])),
          Path.expand(Path.join(__DIR__, "../../../../../fixtures/replay/#{file}"))
        ]

        Enum.find(candidates, &File.exists?/1) || List.last(candidates)
    end
  end

  defp maybe_put_sequence(%Envelope{} = envelope, sequence) when is_nil(sequence), do: envelope

  defp maybe_put_sequence(%Envelope{} = envelope, sequence) do
    metadata = normalize_metadata(envelope.metadata)

    if Map.has_key?(metadata, :sequence) or Map.has_key?(metadata, "sequence") do
      envelope
    else
      put_metadata(envelope, :sequence, sequence)
    end
  end

  defp maybe_put_generated_sequence(%Envelope{} = envelope, generated_sequence)
       when is_nil(generated_sequence),
       do: envelope

  defp maybe_put_generated_sequence(%Envelope{} = envelope, generated_sequence) do
    metadata = normalize_metadata(envelope.metadata)

    if Map.has_key?(metadata, :generated_sequence) or Map.has_key?(metadata, "generated_sequence") do
      envelope
    else
      put_metadata(envelope, :generated_sequence, generated_sequence)
    end
  end

  defp maybe_put_ingested_at(%Envelope{} = envelope, now) when is_nil(now), do: envelope

  defp maybe_put_ingested_at(%Envelope{} = envelope, now) do
    metadata = normalize_metadata(envelope.metadata)

    if Map.has_key?(metadata, :ingested_at) or Map.has_key?(metadata, "ingested_at") do
      envelope
    else
      put_metadata(envelope, :ingested_at, now)
    end
  end

  defp put_metadata(%Envelope{} = envelope, key, value) do
    metadata =
      envelope.metadata
      |> normalize_metadata()
      |> Map.put(key, value)
      |> Map.put(to_string(key), value)

    %{envelope | metadata: metadata}
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
end
