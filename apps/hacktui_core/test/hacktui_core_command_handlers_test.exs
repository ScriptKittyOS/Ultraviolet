defmodule HacktuiCore.CommandHandlersTest do
  use ExUnit.Case, async: true

  alias HacktuiCore.ActorRef
  alias HacktuiCore.CommandHandlers.{Alerting, Audit, Casework, Ingest, Response}

  alias HacktuiCore.Commands.{
    AcceptObservation,
    ApproveAction,
    CreateAlert,
    OpenCase,
    RequestAction,
    TransitionAlert,
    TransitionCase
  }

  alias HacktuiCore.Events.{
    ActionApproved,
    AlertCreated,
    AlertTransitioned,
    AuditRecorded,
    CaseOpened,
    CaseTransitioned,
    ObservationAccepted
  }

  setup do
    actor = ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui)
    %{actor: actor, now: ~U[2026-03-07 00:00:00Z]}
  end

  test "ingest handler accepts observations", %{actor: actor, now: now} do
    command = %AcceptObservation{
      observation_id: "obs-1",
      envelope_version: 1,
      kind: :dns_query,
      source: :sensor,
      summary: "Suspicious DNS query observed",
      raw_message: "dns_query suspicious.example",
      metadata: %{"sensor" => "test"},
      severity: "high",
      confidence: 0.91,
      payload: %{kind: :dns_query},
      observed_at: ~U[2026-03-07 00:00:00Z],
      received_at: ~U[2026-03-07 00:00:01Z],
      actor: actor
    }

    assert {:ok, %ObservationAccepted{} = event} =
             Ingest.handle(command, event_id: "evt-1", accepted_at: now)

    assert event.observation_id == "obs-1"
  end

  # Slice 40: the evidence commitment and the identity survive the command -> event boundary.
  # The event carries the full sha256 of the raw message, never the raw bytes.
  test "ingest handler carries fingerprint and raw_message_sha256 onto the event",
       %{actor: actor, now: now} do
    command = %AcceptObservation{
      observation_id: "obs-2",
      fingerprint: "fp-obs-2",
      envelope_version: 1,
      kind: :dns_query,
      source: :sensor,
      summary: "Suspicious DNS query observed",
      raw_message: "dns_query suspicious.example",
      metadata: %{},
      severity: "high",
      confidence: 0.91,
      payload: %{},
      received_at: ~U[2026-03-07 00:00:01Z],
      actor: actor
    }

    assert {:ok, %ObservationAccepted{} = event} =
             Ingest.handle(command, event_id: "evt-2", accepted_at: now)

    assert Map.fetch!(event, :fingerprint) == "fp-obs-2"

    assert Map.fetch!(event, :raw_message_sha256) ==
             HacktuiCore.Text.original_sha256("dns_query suspicious.example")

    refute Map.has_key?(event, :raw_message)
  end

  test "alerting handler creates and transitions alerts", %{actor: actor, now: now} do
    create = %CreateAlert{
      alert_id: "alert-1",
      title: "Suspicious DNS query",
      severity: :high,
      observation_refs: ["obs-1"],
      actor: actor
    }

    assert {:ok, alert, %AlertCreated{}} =
             Alerting.handle(create, event_id: "evt-2", occurred_at: now)

    transition = %TransitionAlert{
      alert_id: alert.alert_id,
      from_state: :open,
      to_state: :investigating,
      reason: "Analyst investigation started",
      actor: actor
    }

    assert {:ok, transitioned, %AlertTransitioned{} = event} =
             Alerting.handle(alert, transition, event_id: "evt-3", occurred_at: now)

    assert transitioned.state == :investigating
    assert event.to_state == :investigating
  end

  test "casework handler opens and transitions cases", %{actor: actor, now: now} do
    open_case = %OpenCase{
      case_id: "case-1",
      title: "Investigate suspicious DNS",
      source_alert_ids: ["alert-1"],
      actor: actor
    }

    assert {:ok, case_record, %CaseOpened{}} =
             Casework.handle(open_case, event_id: "evt-4", opened_at: now)

    transition_case = %TransitionCase{
      case_id: case_record.case_id,
      from_status: :open,
      to_status: :triage,
      reason: "Initial triage",
      actor: actor
    }

    assert {:ok, transitioned, %CaseTransitioned{} = event} =
             Casework.handle(case_record, transition_case, event_id: "evt-5", occurred_at: now)

    assert transitioned.status == :triage
    assert event.to_status == :triage
  end

  test "response handler requests and approves actions", %{actor: actor, now: now} do
    request = %RequestAction{
      action_request_id: "act-1",
      case_id: "case-1",
      action_class: :contain,
      target: "host-42",
      requested_by: actor,
      reason: "Contain the host"
    }

    assert {:ok, action_request, _event} =
             Response.handle(request, event_id: "evt-6", requested_at: now)

    approve = %ApproveAction{
      action_request_id: action_request.action_request_id,
      approver: actor,
      reason: "Approved by incident commander"
    }

    assert {:ok, approved_request, %ActionApproved{} = event} =
             Response.handle(action_request, approve, event_id: "evt-7", approved_at: now)

    assert approved_request.approval_status == :approved
    assert event.action_request_id == action_request.action_request_id
  end

  test "audit handler records auditable actions", %{actor: actor, now: now} do
    assert {:ok, %AuditRecorded{} = event} =
             Audit.handle(:open_case, actor,
               event_id: "evt-8",
               audit_id: "audit-1",
               occurred_at: now,
               result: :allowed,
               subject: "case-1"
             )

    assert event.action == :open_case
    assert event.result == :allowed
  end
end
