defmodule HacktuiHub.Runtime do
  @moduledoc """
  Thin orchestration layer that composes core command handlers with store persistence flows.

  Upgrades in this version:
  - alert deduplication / correlation
  - threat scoring
  - automatic case creation for high-risk alerts
  - correlation metadata persisted into alert rows
  - actor labels persisted into alert metadata
  - tolerant severity normalization for manual/runtime alert creation
  """

  import Ecto.Query
  require Logger

  alias HacktuiCore.ActorRef
  alias HacktuiCore.AlertLifecycle
  alias HacktuiCore.Commands.CreateAlert
  alias HacktuiCore.Detection
  alias HacktuiCore.Events.{AuditRecorded, ObservationAccepted}

  alias HacktuiHub.{
    AuditService,
    CaseworkService,
    DetectionService,
    IngestService,
    ResponseGovernanceService
  }

  alias HacktuiStore.{
    Actions,
    Alerts,
    Audits,
    Cases,
    Repo
  }

  alias HacktuiStore.Schema.{Alert, CaseRecord}

  @dedupe_window_minutes 30
  @default_case_threshold 70

  @spec accept_observation(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def accept_observation(attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    command =
      attrs
      |> apply_threat_intel_defaults()
      |> enrich_observation_attrs()

    # IngestService.accept_observation/2 returns {:ok, accepted} for every well-formed
    # command; its one raise is a malformed marking (slice 40), which is a caller defect,
    # not a persistence outcome. Persistence failures are surfaced in the result's
    # :persistence field by safely_persist/3 instead.
    {:ok, accepted} = IngestService.accept_observation(command, opts)

    if repo_available?(repo) do
      safely_persist(repo, accepted, opts)
    else
      # Default runtime is HACKTUI_START_REPO=false. Say so rather than claiming a write
      # happened or crashing the sensor.
      {:ok, unpersisted_result(accepted, :skipped_no_repo)}
    end
  end

  # repo_available?/1 can only tell us the Repo *process* is up; the database behind it
  # may still be unreachable. Persistence failures must degrade to a reported error, not
  # an exception that propagates into the sensor's GenServer.
  defp safely_persist(repo, accepted, opts) do
    persist_accepted_observation(repo, accepted, opts)
  rescue
    error ->
      Logger.error("[hacktui_hub] persistence failed: #{Exception.message(error)}")
      {:ok, unpersisted_result(accepted, {:persistence_unavailable, error.__struct__})}
  catch
    :exit, reason ->
      Logger.error("[hacktui_hub] persistence exited: #{inspect(reason)}")
      {:ok, unpersisted_result(accepted, {:persistence_unavailable, :exit})}
  end

  # An observation is always audited. It becomes an alert only when detection promotes it.
  # Slice 40: an observation already audited under the same (source, fingerprint) -- a
  # replayed fixture, a re-forwarded batch -- is reported as `:duplicate` and goes no
  # further: it is not promoted a second time, and no second row is written anywhere.
  defp persist_accepted_observation(repo, accepted, opts) do
    case Audits.persist(repo, observation_audit_event(accepted)) do
      {:ok, %{audit_outcome: :duplicate} = audit_persistence} ->
        {:ok,
         accepted
         |> unpersisted_result(:duplicate)
         |> Map.put(:audit_persistence, audit_persistence)}

      {:ok, audit_persistence} ->
        if Detection.promote?(accepted) do
          promote_observation(repo, accepted, audit_persistence, opts)
        else
          {:ok,
           accepted
           |> unpersisted_result(:audited)
           |> Map.put(:audit_persistence, audit_persistence)}
        end

      other ->
        normalize_persistence_error(other)
    end
  end

  defp promote_observation(repo, accepted, audit_persistence, opts) do
    with {:ok, aggregate, event} <- DetectionService.derive_alert(accepted, opts),
         threat_score <- threat_score(accepted, aggregate),
         {:ok, alert_result_0} <-
           persist_or_correlate_alert(repo, aggregate, event, accepted, threat_score, opts),
         {:ok, case_result} <-
           maybe_open_case_for_alert(repo, alert_result_0.aggregate, accepted, threat_score, opts),
         {:ok, alert_result} <-
           attach_case_metadata(repo, alert_result_0, case_result),
         {:ok, threat_alert} <- maybe_create_threat_alert(accepted, opts) do
      {:ok,
       %{
         observation: accepted,
         promoted: true,
         persistence: :persisted,
         alert: alert_result.aggregate,
         event: alert_result.event,
         correlation: alert_result.correlation,
         audit_persistence: audit_persistence,
         alert_persistence: alert_result.persistence,
         case_result: case_result,
         threat_score: threat_score,
         threat_alert: threat_alert
       }}
    else
      other -> normalize_persistence_error(other)
    end
  end

  defp unpersisted_result(accepted, persistence) do
    %{
      observation: accepted,
      promoted: false,
      persistence: persistence,
      alert: nil,
      event: nil,
      correlation: nil,
      audit_persistence: nil,
      alert_persistence: nil,
      case_result: nil,
      threat_score: nil,
      threat_alert: nil
    }
  end

  # Runtime previously passed the ObservationAccepted straight to Audits.persist/2, which
  # only matches %AuditRecorded{} -- a guaranteed FunctionClauseError, and further proof
  # this path had no callers.
  defp observation_audit_event(%ObservationAccepted{} = accepted) do
    %AuditRecorded{
      event_id: "audit-#{accepted.event_id}",
      audit_id: "obs-#{accepted.observation_id}",
      actor: normalize_actor(accepted.actor),
      action: :observation_accepted,
      occurred_at: accepted.accepted_at,
      result: :accepted,
      subject: to_string(accepted.observation_id),
      source: to_string_or_nil(accepted.source),
      fingerprint: accepted.fingerprint,
      marking: accepted.marking,
      metadata: %{
        raw_message_sha256: accepted.raw_message_sha256,
        fingerprint: accepted.fingerprint,
        kind: to_string_or_nil(accepted.kind)
      }
    }
  end

  # The marking and identity an alert or case inherits from the observation that promoted
  # it. `nil` marking means the store writes the enclave marking (a manually created alert
  # has no observation); the fingerprint is simply absent then.
  defp provenance_opts(%ObservationAccepted{} = accepted),
    do: [marking: accepted.marking, fingerprint: accepted.fingerprint]

  defp provenance_opts(_no_observation), do: []

  # Collectors set actor to a plain string; Audits.audit_changeset/1 expects an ActorRef
  # and does event.actor.id, which raised BadMapError on every live observation.
  defp normalize_actor(%ActorRef{} = actor), do: actor

  defp normalize_actor(actor) when is_binary(actor),
    do: %ActorRef{id: actor, type: :service, role: :sensor, source: :hacktui_sensor}

  defp normalize_actor(_),
    do: %ActorRef{id: "unknown", type: :service, role: :sensor, source: :hacktui_sensor}

  # HacktuiStore returns Ecto.Multi's {:error, step, reason, changes} on failure. Every
  # public function here is @spec'd {:ok, map()} | {:error, term()}, and none of these
  # `with` blocks had an `else`, so the raw 4-tuple leaked to callers.
  # Forwarder.normalize_rpc_result/1 then turned that leak into SUCCESS.
  defp normalize_persistence_error({:error, step, reason, _changes}), do: {:error, {step, reason}}
  defp normalize_persistence_error({:error, reason}), do: {:error, reason}
  defp normalize_persistence_error(other), do: {:error, other}

  defp repo_available?(repo) do
    is_atom(repo) and Code.ensure_loaded?(repo) and
      function_exported?(repo, :transaction, 1) and not is_nil(Process.whereis(repo))
  end

  @spec create_alert(struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_alert(command, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    command = normalize_create_alert_command(command)

    with {:ok, aggregate, event} <- DetectionService.create_alert(command, opts),
         threat_score <- threat_score(nil, aggregate),
         {:ok, alert_result_0} <-
           persist_or_correlate_alert(repo, aggregate, event, nil, threat_score, opts),
         {:ok, case_result} <-
           maybe_open_case_for_alert(repo, alert_result_0.aggregate, nil, threat_score, opts),
         {:ok, alert_result} <-
           attach_case_metadata(repo, alert_result_0, case_result) do
      {:ok,
       %{
         aggregate: alert_result.aggregate,
         event: alert_result.event,
         persistence: alert_result.persistence,
         correlation: alert_result.correlation,
         case_result: case_result,
         threat_score: threat_score
       }}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec transition_alert(struct(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def transition_alert(alert, command, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, aggregate, event} <- DetectionService.transition_alert(alert, command, opts),
         {:ok, persistence} <- Alerts.persist_transition(repo, aggregate, event) do
      {:ok, %{aggregate: aggregate, event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec open_case(struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_case(command, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, aggregate, event} <- CaseworkService.open_case(command, opts),
         {:ok, persistence} <-
           Cases.persist_open(
             repo,
             aggregate,
             event,
             Keyword.take(opts, [:marking, :fingerprint])
           ) do
      {:ok, %{aggregate: aggregate, event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec transition_case(struct(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def transition_case(case_record, command, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, aggregate, event} <- CaseworkService.transition_case(case_record, command, opts),
         {:ok, persistence} <- Cases.persist_transition(repo, aggregate, event) do
      {:ok, %{aggregate: aggregate, event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec request_action(struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_action(command, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, aggregate, event} <- ResponseGovernanceService.request_action(command, opts),
         {:ok, persistence} <- Actions.persist_request(repo, aggregate, event) do
      {:ok, %{aggregate: aggregate, event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec approve_action(struct(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve_action(action_request, command, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, aggregate, event} <-
           ResponseGovernanceService.approve_action(action_request, command, opts),
         {:ok, persistence} <- Actions.persist_approval(repo, aggregate, event) do
      {:ok, %{aggregate: aggregate, event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  @spec record_audit(atom(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_audit(action, actor, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, event} <- AuditService.record(action, actor, opts),
         {:ok, persistence} <- Audits.persist(repo, event) do
      {:ok, %{event: event, persistence: persistence}}
    else
      other -> normalize_persistence_error(other)
    end
  end

  #
  # Threat intel / observation enrichment
  #

  defp apply_threat_intel_defaults(attrs) when is_map(attrs) do
    metadata = attrs |> map_get(:metadata) |> normalize_metadata_map()
    threat_context = metadata |> map_get(:threat_context) |> normalize_threat_context()

    attrs
    |> put_if_missing(:metadata, metadata)
    |> maybe_apply_threat_context(threat_context)
  end

  defp enrich_observation_attrs(attrs) when is_map(attrs) do
    metadata = attrs |> map_get(:metadata) |> normalize_metadata_map()
    threat_context = metadata |> map_get(:threat_context) |> normalize_threat_context()

    metadata =
      case threat_context do
        nil -> metadata
        context -> Map.put(metadata, :threat_context, context)
      end

    attrs
    |> Map.put(:metadata, metadata)
    |> put_if_missing(:summary, attrs |> map_get(:raw_message))
  end

  defp maybe_apply_threat_context(attrs, nil),
    do: Map.put(attrs, :metadata, normalize_metadata_map(map_get(attrs, :metadata)))

  defp maybe_apply_threat_context(attrs, threat_context) do
    metadata =
      attrs
      |> map_get(:metadata)
      |> normalize_metadata_map()
      |> Map.put(:threat_context, threat_context)

    attrs
    |> Map.put(:metadata, metadata)
    |> put_if_missing(:severity, Map.get(threat_context, :severity))
  end

  defp normalize_threat_context(nil), do: nil

  defp normalize_threat_context(threat_context) when is_map(threat_context) do
    keyword = map_get(threat_context, :keyword)
    severity = threat_context |> map_get(:severity) |> normalize_severity()
    source = map_get(threat_context, :source)

    tactic = map_get(threat_context, :tactic)
    technique = map_get(threat_context, :technique)
    matched_field = map_get(threat_context, :matched_field)
    matched_text = map_get(threat_context, :matched_text)

    %{}
    |> maybe_put(:keyword, keyword)
    |> maybe_put(:severity, severity)
    |> maybe_put(:source, source)
    |> maybe_put(:tactic, tactic)
    |> maybe_put(:technique, technique)
    |> maybe_put(:matched_field, matched_field)
    |> maybe_put(:matched_text, matched_text)
    |> case do
      %{} = normalized when map_size(normalized) == 0 -> nil
      normalized -> normalized
    end
  end

  defp normalize_threat_context(_), do: nil

  # Preserves the caller's keys. This previously ran every key through
  # String.to_existing_atom/1, so a replay fixture's metadata["sequence"] silently became
  # metadata[:sequence] and the original lookup returned nil. Normalisation should add
  # the derived threat_context, not rewrite the caller's data.
  defp normalize_metadata_map(metadata) when is_map(metadata) do
    threat_context = metadata |> map_get(:threat_context) |> normalize_threat_context()

    metadata = Map.drop(metadata, [nil])

    case threat_context do
      nil -> Map.delete(metadata, :threat_context)
      context -> Map.put(metadata, :threat_context, context)
    end
  end

  defp normalize_metadata_map(_), do: %{}

  #
  # Severity / scoring
  #

  defp normalize_severity(nil), do: nil

  defp normalize_severity(severity) when severity in [:low, :medium, :high, :critical],
    do: severity

  defp normalize_severity(severity) when is_binary(severity) do
    case String.downcase(severity) do
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "critical" -> :critical
      _ -> nil
    end
  end

  defp normalize_severity(_), do: nil

  defp threat_score(observation, aggregate) do
    severity_score =
      aggregate
      |> Map.get(:severity)
      |> normalize_severity()
      |> case do
        :critical -> 90
        :high -> 70
        :medium -> 45
        :low -> 20
        _ -> 10
      end

    observation_bonus =
      case observation_kind(observation) do
        "journald.security" -> 18
        "network.flow" -> 12
        "system.error" -> 10
        _ -> 0
      end

    threat_context_bonus =
      observation
      |> observation_metadata()
      |> map_get(:threat_context)
      |> normalize_threat_context()
      |> case do
        %{severity: :critical} -> 20
        %{severity: :high} -> 16
        %{severity: :medium} -> 10
        %{severity: :low} -> 4
        %{} -> 8
        _ -> 0
      end

    network_bonus =
      observation
      |> observation_payload()
      |> network_risk_bonus()

    min(severity_score + observation_bonus + threat_context_bonus + network_bonus, 100)
  end

  defp network_risk_bonus(payload) when is_map(payload) do
    service = map_get(payload, :service) |> to_string_or_nil()
    site = map_get(payload, :site) |> to_string_or_nil()
    dst_port = map_get(payload, :dst_port)

    cond do
      service == "HTTPS" and not is_nil(site) -> 8
      service == "HTTP" -> 12
      dst_port in [22, 3389, 5900] -> 16
      dst_port in [443, 80, 53] -> 6
      true -> 0
    end
  end

  defp network_risk_bonus(_), do: 0

  #
  # Dedup / correlation
  #

  defp persist_or_correlate_alert(repo, aggregate, event, observation, threat_score, opts) do
    correlation_window =
      Keyword.get(opts, :correlation_window_minutes, @dedupe_window_minutes)

    case find_correlated_alert(repo, aggregate, observation, correlation_window) do
      nil ->
        with {:ok, persistence} <-
               Alerts.persist_create(repo, aggregate, event, alert_provenance(observation, opts)),
             {:ok, metadata_row} <-
               persist_alert_correlation_metadata(
                 repo,
                 Map.get(aggregate, :alert_id),
                 aggregate,
                 event,
                 observation,
                 threat_score,
                 false
               ) do
          updated_aggregate =
            case metadata_row do
              %Alert{} = row -> alert_schema_to_aggregate(row)
              _ -> aggregate
            end

          {:ok,
           %{
             aggregate: updated_aggregate,
             event: event,
             persistence: Map.put(persistence, :metadata_update, metadata_row),
             correlation: %{
               deduplicated?: false,
               reason: nil,
               threat_score: threat_score
             }
           }}
        end

      %Alert{} = existing ->
        with {:ok, metadata_row} <-
               persist_alert_correlation_metadata(
                 repo,
                 existing.alert_id,
                 aggregate,
                 event,
                 observation,
                 threat_score,
                 true
               ) do
          final_row =
            case metadata_row do
              %Alert{} = row -> row
              _ -> existing
            end

          {:ok,
           %{
             aggregate: alert_schema_to_aggregate(final_row),
             event: event,
             persistence: %{reused_alert: final_row, metadata_update: metadata_row},
             correlation: %{
               deduplicated?: true,
               reason: :correlated_existing_alert,
               existing_alert_id: final_row.alert_id,
               threat_score: threat_score
             }
           }}
        end
    end
  end

  # An observation's provenance wins; a manual alert may carry its own in opts.
  defp alert_provenance(%ObservationAccepted{} = observation, _opts),
    do: provenance_opts(observation)

  defp alert_provenance(_no_observation, opts), do: Keyword.take(opts, [:marking, :fingerprint])

  defp find_correlated_alert(repo, aggregate, observation, window_minutes) do
    title = Map.get(aggregate, :title)
    severity = aggregate |> Map.get(:severity) |> normalize_severity() |> severity_to_string()
    now = DateTime.utc_now()
    since = DateTime.add(now, -window_minutes * 60, :second)
    site = observation |> observation_payload() |> map_get(:site) |> to_string_or_nil()

    base_query =
      from(alert in Alert,
        where:
          alert.title == ^title and
            alert.severity == ^severity and
            alert.state in ["open", "investigating"] and
            alert.inserted_at >= ^since,
        order_by: [desc: alert.inserted_at],
        limit: 5
      )

    repo
    |> safe_repo_all(base_query)
    |> Enum.find(fn %Alert{} = alert ->
      existing_site =
        alert.metadata
        |> normalize_store_metadata()
        |> map_get(:site)
        |> to_string_or_nil()

      case {site, existing_site} do
        {nil, _} -> true
        {_, nil} -> true
        {s1, s2} -> s1 == s2
      end
    end)
  end

  defp persist_alert_correlation_metadata(
         repo,
         alert_id,
         aggregate,
         event,
         observation,
         threat_score,
         deduplicated?
       ) do
    case repo.get_by(Alert, alert_id: alert_id) do
      nil ->
        {:ok, nil}

      %Alert{} = row ->
        existing_meta = normalize_store_metadata(row.metadata)
        now = event_timestamp(event)
        actor_label = actor_label(event)

        updated_meta =
          existing_meta
          |> Map.put_new("first_seen_at", now)
          |> Map.put("last_seen_at", now)
          |> Map.put("last_event_id", Map.get(event, :event_id))
          |> Map.put(
            "threat_score",
            max(existing_int(existing_meta["threat_score"]), threat_score)
          )
          |> Map.put("deduplicated", deduplicated?)
          |> Map.put("hit_count", existing_int(existing_meta["hit_count"]) + 1)
          |> Map.put(
            "observation_refs",
            merged_observation_refs(existing_meta, aggregate, observation)
          )
          |> maybe_put("site", observation |> observation_payload() |> map_get(:site))
          |> maybe_put("service", observation |> observation_payload() |> map_get(:service))
          |> maybe_put("observation_kind", observation_kind(observation))
          |> maybe_put("latest_title", Map.get(aggregate, :title))
          |> maybe_put("actor_label", actor_label)

        row
        |> Ecto.Changeset.change(%{
          metadata: updated_meta,
          updated_at: DateTime.utc_now()
        })
        |> repo.update()
    end
  end

  defp attach_case_metadata(_repo, alert_result, nil), do: {:ok, alert_result}

  defp attach_case_metadata(repo, alert_result, case_result) do
    case_id = map_get(case_result, :case_id)

    if is_nil(case_id) do
      {:ok, alert_result}
    else
      case repo.get_by(Alert, alert_id: Map.get(alert_result.aggregate, :alert_id)) do
        nil ->
          {:ok, alert_result}

        %Alert{} = row ->
          metadata =
            row.metadata
            |> normalize_store_metadata()
            |> Map.put("linked_case_id", case_id)
            |> Map.put("case_status", to_string(map_get(case_result, :status) || "open"))

          case repo.update(
                 Ecto.Changeset.change(row, %{metadata: metadata, updated_at: DateTime.utc_now()})
               ) do
            {:ok, updated_row} ->
              {:ok,
               %{
                 alert_result
                 | aggregate: alert_schema_to_aggregate(updated_row),
                   persistence:
                     Map.put(alert_result.persistence, :case_metadata_update, updated_row),
                   correlation:
                     Map.merge(alert_result.correlation, %{
                       linked_case_id: case_id
                     })
               }}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp merged_observation_refs(existing_meta, aggregate, observation) do
    from_meta = existing_meta["observation_refs"] || existing_meta[:observation_refs] || []
    from_aggregate = Map.get(aggregate, :observation_refs) || []

    from_observation =
      case observation do
        %{observation_id: id} when not is_nil(id) -> [id]
        _ -> []
      end

    (from_meta ++ from_aggregate ++ from_observation)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp existing_int(value) when is_integer(value), do: value

  defp existing_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp existing_int(_), do: 0

  defp event_timestamp(%{occurred_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp event_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp actor_label(%{actor: actor}), do: actor_to_label(actor)
  defp actor_label(_), do: nil

  defp actor_to_label(nil), do: nil

  defp actor_to_label(actor) when is_binary(actor) do
    actor
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.upcase(value)
    end
  end

  defp actor_to_label(%{id: id}) when is_binary(id) do
    id
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.upcase(value)
    end
  end

  defp actor_to_label(%{source: source}) when is_atom(source) do
    source
    |> Atom.to_string()
    |> String.upcase()
  end

  defp actor_to_label(value) do
    value
    |> to_string()
    |> String.upcase()
  end

  defp alert_schema_to_aggregate(%Alert{} = alert) do
    struct(HacktuiCore.Aggregates.Alert, %{
      alert_id: alert.alert_id,
      title: alert.title,
      severity: normalize_severity(alert.severity) || :medium,
      state: normalize_alert_state(alert.state),
      disposition: normalize_disposition(alert.disposition),
      observation_refs:
        alert.metadata
        |> normalize_store_metadata()
        |> map_get(:observation_refs)
        |> normalize_string_list(),
      inserted_at: alert.inserted_at,
      updated_at: alert.updated_at
    })
  rescue
    _ ->
      %{
        alert_id: alert.alert_id,
        title: alert.title,
        severity: normalize_severity(alert.severity) || :medium,
        state: normalize_alert_state(alert.state),
        disposition: normalize_disposition(alert.disposition),
        observation_refs:
          alert.metadata
          |> normalize_store_metadata()
          |> map_get(:observation_refs)
          |> normalize_string_list(),
        inserted_at: alert.inserted_at,
        updated_at: alert.updated_at
      }
  end

  #
  # Automatic case creation
  #

  defp maybe_open_case_for_alert(repo, aggregate, observation, threat_score, opts) do
    if Keyword.get(opts, :skip_casework, false) do
      {:ok, nil}
    else
      threshold = Keyword.get(opts, :case_threshold, @default_case_threshold)

      if should_open_case?(aggregate, threat_score, threshold) do
        case find_existing_case_for_alert(repo, aggregate) do
          nil ->
            build_and_open_case(repo, aggregate, observation, threat_score, opts)

          %CaseRecord{} = existing ->
            {:ok,
             %{
               deduplicated?: true,
               case_id: existing.case_id,
               status: existing.status,
               reason: :existing_case
             }}
        end
      else
        {:ok, nil}
      end
    end
  end

  defp should_open_case?(aggregate, threat_score, threshold) do
    severity = aggregate |> Map.get(:severity) |> normalize_severity()
    severity in [:critical, :high] or threat_score >= threshold
  end

  defp find_existing_case_for_alert(repo, aggregate) do
    title = case_title_for_alert(aggregate)

    query =
      from(case_record in CaseRecord,
        where:
          case_record.title == ^title and
            case_record.status in ["open", "triage", "active_investigation"],
        order_by: [desc: case_record.updated_at],
        limit: 1
      )

    repo
    |> safe_repo_all(query)
    |> List.first()
  end

  defp build_and_open_case(repo, aggregate, observation, threat_score, opts) do
    command_module = Module.concat([HacktuiCore.Commands, OpenCase])

    cond do
      not Code.ensure_loaded?(command_module) ->
        Logger.warning("OpenCase command module not available; skipping auto-case creation")
        {:ok, nil}

      true ->
        now = DateTime.utc_now()

        case_opts =
          opts
          |> Keyword.put(:repo, repo)
          |> Keyword.merge(provenance_opts(observation))
          |> Keyword.put_new(:opened_at, now)
          |> Keyword.put_new(:occurred_at, now)
          |> Keyword.put_new(
            :event_id,
            "evt-case-open-#{Map.get(aggregate, :alert_id)}-#{System.unique_integer([:positive])}"
          )

        case_command =
          command_module
          |> struct()
          |> put_struct_if_supported(:case_id, "case-alert-#{Map.get(aggregate, :alert_id)}")
          |> put_struct_if_supported(:title, case_title_for_alert(aggregate))
          |> put_struct_if_supported(:status, :triage)
          |> put_struct_if_supported(:assigned_to, "auto-triage")
          |> put_struct_if_supported(:actor, case_actor())
          |> put_struct_if_supported(
            :metadata,
            %{
              source: "runtime.auto_case",
              alert_id: Map.get(aggregate, :alert_id),
              threat_score: threat_score,
              observation_kind: observation_kind(observation),
              seeded: false
            }
          )

        case open_case(case_command, case_opts) do
          {:ok, result} ->
            aggregate_case = Map.get(result, :aggregate)
            persistence = Map.get(result, :persistence, %{})
            persisted_case = Map.get(persistence, :case_open)

            case_id =
              cond do
                is_map(aggregate_case) and Map.has_key?(aggregate_case, :case_id) ->
                  Map.get(aggregate_case, :case_id)

                is_map(persisted_case) and Map.has_key?(persisted_case, :case_id) ->
                  Map.get(persisted_case, :case_id)

                true ->
                  nil
              end

            status =
              cond do
                is_map(aggregate_case) and Map.has_key?(aggregate_case, :status) ->
                  Map.get(aggregate_case, :status)

                is_map(persisted_case) and Map.has_key?(persisted_case, :status) ->
                  Map.get(persisted_case, :status)

                true ->
                  "triage"
              end

            {:ok,
             %{
               deduplicated?: false,
               case_id: case_id,
               status: status,
               threat_score: threat_score,
               # Slice 40: exposed so the marking and fingerprint the case was opened with
               # can be asserted without a database.
               persistence: persistence
             }}

          {:error, reason} ->
            Logger.warning("auto-case creation failed: #{inspect(reason)}")

            {:ok,
             %{
               deduplicated?: false,
               case_id: nil,
               status: :failed,
               threat_score: threat_score,
               error: reason
             }}
        end
    end
  end

  defp case_title_for_alert(aggregate) do
    "Case - " <> (Map.get(aggregate, :title) || "untitled alert")
  end

  defp case_actor do
    ActorRef.new!(id: "auto-case", type: :system, role: :automation, source: :runtime)
  end

  #
  # Threat-intel generated alerts
  #

  defp maybe_create_threat_alert(%{metadata: metadata} = observation, opts)
       when is_map(metadata) do
    case normalize_threat_context(map_get(metadata, :threat_context)) do
      nil ->
        {:ok, nil}

      threat_context ->
        command = %CreateAlert{
          alert_id: "threat-#{observation.observation_id}",
          title: threat_alert_title(threat_context, observation),
          severity: Map.get(threat_context, :severity) || :medium,
          observation_refs: [observation.observation_id],
          actor: threat_actor()
        }

        create_alert(command, Keyword.put(opts, :skip_casework, true))
    end
  end

  defp maybe_create_threat_alert(_, _opts), do: {:ok, nil}

  defp threat_alert_title(threat_context, observation) do
    keyword = Map.get(threat_context, :keyword) || "threat intel match"
    kind = Map.get(observation, :kind) || "observation"
    "Threat intel hit: #{keyword} (#{kind})"
  end

  defp threat_actor do
    ActorRef.new!(id: "threat-intel", type: :system, role: :automation, source: :threat_intel)
  end

  #
  # Generic helpers
  #

  defp normalize_create_alert_command(%CreateAlert{} = command) do
    %{command | severity: normalize_severity(command.severity) || :medium}
  end

  defp normalize_create_alert_command(command), do: command

  @doc false
  @spec normalize_alert_state(term()) :: atom()
  def normalize_alert_state(nil), do: :open
  def normalize_alert_state(state) when is_atom(state), do: state

  # Derived from AlertLifecycle so the domain is the single source of truth. The previous
  # case handled three of six states and mapped everything else to :open, so a resolved
  # alert re-materialised as open on every read.
  def normalize_alert_state(state) when is_binary(state) do
    downcased = String.downcase(state)
    Enum.find(AlertLifecycle.states(), :open, &(Atom.to_string(&1) == downcased))
  end

  def normalize_alert_state(_), do: :open

  @doc false
  @spec normalize_disposition(term()) :: atom()
  def normalize_disposition(nil), do: :unknown
  def normalize_disposition(disposition) when is_atom(disposition), do: disposition

  # The previous case accepted "benign" and "malicious", which are not canonical
  # dispositions, while benign_true_activity -- what DemoSeed writes -- fell through to
  # :unknown, erasing the analyst's decision on every read.
  def normalize_disposition(disposition) when is_binary(disposition) do
    downcased = String.downcase(disposition)
    Enum.find(AlertLifecycle.dispositions(), :unknown, &(Atom.to_string(&1) == downcased))
  end

  def normalize_disposition(_), do: :unknown

  defp severity_to_string(nil), do: "medium"
  defp severity_to_string(severity) when is_atom(severity), do: Atom.to_string(severity)
  defp severity_to_string(severity), do: to_string(severity)

  defp normalize_store_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_store_metadata(_), do: %{}

  defp normalize_string_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [to_string(value)]

  defp observation_kind(nil), do: nil
  defp observation_kind(observation) when is_map(observation), do: map_get(observation, :kind)
  defp observation_kind(_), do: nil

  defp observation_metadata(nil), do: %{}

  defp observation_metadata(observation) when is_map(observation),
    do: map_get(observation, :metadata) || %{}

  defp observation_metadata(_), do: %{}

  defp observation_payload(nil), do: %{}

  defp observation_payload(observation) when is_map(observation),
    do: map_get(observation, :payload) || %{}

  defp observation_payload(_), do: %{}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp put_if_missing(map, _key, nil), do: map

  defp put_if_missing(map, key, value) do
    if Map.has_key?(map, key) and not is_nil(Map.get(map, key)) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_struct_if_supported(struct_value, key, value) when is_map(struct_value) do
    if Map.has_key?(struct_value, key) do
      Map.put(struct_value, key, value)
    else
      struct_value
    end
  end

  defp safe_repo_all(repo, query) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :all, 1) do
      repo.all(query)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
