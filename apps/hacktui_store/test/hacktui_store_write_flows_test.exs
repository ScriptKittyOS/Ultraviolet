defmodule HacktuiStore.WriteFlowsTest do
  use ExUnit.Case, async: true

  alias HacktuiCore.ActorRef
  alias HacktuiCore.Aggregates.{ActionRequest, Alert, InvestigationCase}

  alias HacktuiCore.Commands.{
    ApproveAction,
    CreateAlert,
    OpenCase,
    RequestAction,
    TransitionAlert,
    TransitionCase
  }

  alias HacktuiStore.{Actions, Alerts, Audits, Cases}
  alias HacktuiStore.TestSupport.FakeRepo

  setup do
    actor = ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui)
    now = ~U[2026-03-07 00:00:00Z]

    {:ok, alert, created_event} =
      Alert.create(
        %CreateAlert{
          alert_id: "alert-1",
          title: "Suspicious DNS query",
          severity: :high,
          observation_refs: ["obs-1"],
          actor: actor
        },
        event_id: "evt-1",
        occurred_at: now
      )

    {:ok, transitioned_alert, transitioned_event} =
      Alert.transition(
        alert,
        %TransitionAlert{
          alert_id: "alert-1",
          from_state: :open,
          to_state: :investigating,
          reason: "Analyst started investigation",
          actor: actor
        },
        event_id: "evt-2",
        occurred_at: now
      )

    {:ok, case_record, case_opened} =
      InvestigationCase.open(
        %OpenCase{
          case_id: "case-1",
          title: "Investigate suspicious DNS",
          source_alert_ids: ["alert-1"],
          actor: actor
        },
        event_id: "evt-3",
        opened_at: now
      )

    {:ok, triaged_case, case_transitioned} =
      InvestigationCase.transition(
        case_record,
        %TransitionCase{
          case_id: "case-1",
          from_status: :open,
          to_status: :triage,
          reason: "Analyst started triage",
          actor: actor
        },
        event_id: "evt-4",
        occurred_at: now
      )

    {:ok, action_request, action_requested} =
      ActionRequest.request(
        %RequestAction{
          action_request_id: "act-1",
          case_id: "case-1",
          action_class: :contain,
          target: "host-42",
          requested_by: actor,
          reason: "Contain the host"
        },
        event_id: "evt-5",
        requested_at: now
      )

    {:ok, approved_action_request, action_approved} =
      ActionRequest.approve(
        action_request,
        %ApproveAction{
          action_request_id: "act-1",
          approver: actor,
          reason: "Approved by incident commander"
        },
        event_id: "evt-6",
        approved_at: now
      )

    audit_event = %HacktuiCore.Events.AuditRecorded{
      event_id: "evt-7",
      audit_id: "audit-1",
      actor: actor,
      action: :approve_action,
      occurred_at: now,
      result: :allowed,
      subject: "act-1"
    }

    %{
      alert: alert,
      created_event: created_event,
      transitioned_alert: transitioned_alert,
      transitioned_event: transitioned_event,
      case_record: case_record,
      case_opened: case_opened,
      triaged_case: triaged_case,
      case_transitioned: case_transitioned,
      action_request: action_request,
      action_requested: action_requested,
      approved_action_request: approved_action_request,
      action_approved: action_approved,
      audit_event: audit_event
    }
  end

  test "persists a created alert via an Ecto.Multi", %{alert: alert, created_event: created_event} do
    assert {:ok, operations} = Alerts.persist_create(FakeRepo, alert, created_event)

    assert {:insert, changeset, _opts} = FakeRepo.operations().alert_insert
    assert changeset.changes.alert_id == "alert-1"
    assert changeset.changes.state == "open"
    assert changeset.changes.disposition == "unknown"
  end

  test "persists an alert transition via an Ecto.Multi", %{
    transitioned_alert: alert,
    transitioned_event: event
  } do
    assert {:ok, operations} = Alerts.persist_transition(FakeRepo, alert, event)

    assert {:update_all, query, updates, _opts} = FakeRepo.operations().alert_state_update
    assert query.from.source == {"alerts", HacktuiStore.Schema.Alert}
    assert [set: set_updates] = updates
    assert {:state, "investigating"} in set_updates

    assert {:insert, changeset, _opts} = FakeRepo.operations().alert_transition_insert
    assert changeset.changes.to_state == "investigating"
  end

  test "persists case open and transition flows", %{
    case_record: case_record,
    case_opened: opened,
    triaged_case: triaged_case,
    case_transitioned: transitioned
  } do
    assert {:ok, open_ops} = Cases.persist_open(FakeRepo, case_record, opened)
    assert {:insert, case_changeset, _opts} = FakeRepo.operations().case_insert
    assert case_changeset.changes.case_id == "case-1"
    assert case_changeset.changes.status == "open"

    assert {:ok, transition_ops} = Cases.persist_transition(FakeRepo, triaged_case, transitioned)

    assert {:update_all, query, updates, _opts} = FakeRepo.operations().case_status_update

    assert query.from.source == {"cases", HacktuiStore.Schema.CaseRecord}
    assert [set: set_updates] = updates
    assert {:status, "triage"} in set_updates

    assert {:insert, timeline_changeset, _opts} = FakeRepo.operations().case_timeline_insert

    assert timeline_changeset.changes.case_id == "case-1"
    assert timeline_changeset.changes.entry_type == "case_transitioned"
  end

  test "persists action request and approval flows", %{
    action_request: action_request,
    action_requested: action_requested,
    approved_action_request: approved_action_request,
    action_approved: action_approved
  } do
    assert {:ok, request_ops} =
             Actions.persist_request(FakeRepo, action_request, action_requested)

    assert {:insert, request_changeset, _opts} = FakeRepo.operations().action_request_insert
    assert request_changeset.changes.action_request_id == "act-1"
    assert request_changeset.changes.approval_status == "pending_approval"

    assert {:ok, approval_ops} =
             Actions.persist_approval(FakeRepo, approved_action_request, action_approved)

    assert {:update_all, query, updates, _opts} = FakeRepo.operations().action_request_update

    assert query.from.source == {"action_requests", HacktuiStore.Schema.ActionRequest}
    assert [set: set_updates] = updates
    assert {:approval_status, "approved"} in set_updates
  end

  test "persists audit records", %{audit_event: audit_event} do
    assert {:ok, operations} = Audits.persist(FakeRepo, audit_event)
    assert operations.audit_outcome == :inserted

    # Slice 40: one validated row through insert_all, ON CONFLICT DO NOTHING.
    assert {:insert_all, HacktuiStore.Schema.AuditEvent, [row], opts} =
             FakeRepo.operations().audit_insert

    assert opts[:on_conflict] == :nothing
    # Scoped to the identity index: an audit_id collision must stay an error.
    assert opts[:conflict_target] == Audits.identity_index()
    assert {:unsafe_fragment, fragment} = opts[:conflict_target]
    assert fragment =~ "(source, fingerprint)"
    assert fragment =~ "fingerprint IS NOT NULL"
    assert row.audit_id == "audit-1"
    assert row.action == "approve_action"
    assert row.marking.classification == "U"
  end
end
