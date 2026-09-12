defmodule HacktuiStore.DemoSeed do
  @moduledoc """
  Creates deterministic demo data for case-1.
  """

  import Ecto.Query

  alias HacktuiStore.Repo

  alias HacktuiStore.Schema.{
    ActionRequest,
    Alert,
    AlertTransition,
    AuditEvent,
    CaseRecord,
    CaseTimelineEntry
  }

  @case_id "case-1"
  @alert_ids ["alert-1", "alert-2", "alert-3"]
  @seeded_at ~U[2026-03-07 13:00:00.000000Z]
  @linked_at ~U[2026-03-07 13:00:10.000000Z]

  @spec seed_case_1!(keyword() | map()) :: map()
  def seed_case_1!(opts \\ []) do
    opts = normalize_opts(opts)
    repo = Keyword.get(opts, :repo, Repo)

    cleanup_case_1!(repo)

    now = @seeded_at

    alerts = [
      %{
        id: Ecto.UUID.generate(),
        alert_id: "alert-1",
        # Slice 40: seeded rows are marked like any other row; insert_all bypasses the changeset.
        marking: HacktuiCore.Marking.enclave(),
        title: "Beaconing to malicious.example",
        severity: "high",
        state: "investigating",
        disposition: "unknown",
        metadata: %{
          indicators: ["malicious.example", "10.0.0.4"],
          seeded: true
        },
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        alert_id: "alert-2",
        # Slice 40: seeded rows are marked like any other row; insert_all bypasses the changeset.
        marking: HacktuiCore.Marking.enclave(),
        title: "Repeat DNS lookup for malicious.example",
        severity: "medium",
        state: "open",
        disposition: "unknown",
        metadata: %{
          indicators: ["malicious.example"],
          seeded: true
        },
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        alert_id: "alert-3",
        # Slice 40: seeded rows are marked like any other row; insert_all bypasses the changeset.
        marking: HacktuiCore.Marking.enclave(),
        title: "Benign lookup noise",
        severity: "low",
        state: "open",
        disposition: "benign_true_activity",
        metadata: %{
          indicators: ["benign.example"],
          seeded: true
        },
        inserted_at: now,
        updated_at: now
      }
    ]

    case_record = %{
      id: Ecto.UUID.generate(),
      case_id: @case_id,
      title: "Case 1 - Suspicious DNS investigation",
      status: "triage",
      # Slice 40: seeded rows are marked like any other row; insert_all bypasses the changeset.
      marking: HacktuiCore.Marking.enclave(),
      assigned_to: "demo-operator",
      metadata: %{
        seeded: true,
        primary_indicator: "malicious.example"
      },
      inserted_at: now,
      updated_at: now
    }

    timeline_entries = [
      %{
        id: Ecto.UUID.generate(),
        case_id: @case_id,
        entry_type: "case_opened",
        summary: "Case opened for suspicious DNS activity",
        occurred_at: now,
        actor_id: "demo-seed",
        metadata: %{
          indicators: ["malicious.example"],
          seeded: true
        },
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        case_id: @case_id,
        entry_type: "alert_linked",
        summary: "Linked repeated beaconing indicators to host 10.0.0.4",
        occurred_at: @linked_at,
        actor_id: "demo-seed",
        metadata: %{
          indicators: ["malicious.example", "10.0.0.4"],
          seeded: true,
          recommendation: "Request approval for SIMULATED containment of host-42"
        },
        inserted_at: now,
        updated_at: now
      }
    ]

    repo.insert_all(Alert, alerts)
    repo.insert_all(CaseRecord, [case_record])
    repo.insert_all(CaseTimelineEntry, timeline_entries)

    %{
      case_id: @case_id,
      alert_ids: @alert_ids,
      seeded_alert_count: length(alerts),
      seeded_timeline_count: length(timeline_entries)
    }
  end

  @spec cleanup_case_1!(module()) :: :ok
  def cleanup_case_1!(repo \\ Repo) do
    repo.delete_all(
      from(action_request in ActionRequest, where: action_request.case_id == ^@case_id)
    )

    repo.delete_all(
      from(audit in AuditEvent, where: audit.subject == ^@case_id or audit.subject in ^@alert_ids)
    )

    repo.delete_all(from(entry in CaseTimelineEntry, where: entry.case_id == ^@case_id))
    repo.delete_all(from(case_record in CaseRecord, where: case_record.case_id == ^@case_id))

    repo.delete_all(
      from(transition in AlertTransition, where: transition.alert_id in ^@alert_ids)
    )

    repo.delete_all(from(alert in Alert, where: alert.alert_id in ^@alert_ids))
    :ok
  end

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
end
