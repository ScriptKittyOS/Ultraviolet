defmodule HacktuiStore.StoreDbIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

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

  alias HacktuiStore.{Actions, Alerts, Audits, Cases, Health, ReadModels, Repo}
  alias HacktuiStore.Schema.Alert, as: AlertRecord
  alias HacktuiStore.Schema.ActionRequest, as: ActionRequestRecord
  alias HacktuiStore.Schema.{AlertTransition, AuditEvent, CaseRecord, CaseTimelineEntry}

  alias HacktuiStore.TestSupport.Integration

  setup_all do
    Integration.require_db_env!()
    Integration.start_repo!()
    migrations = Integration.migrate!()

    on_exit(fn ->
      Integration.stop_repo!()
    end)

    %{migrations: migrations}
  end

  setup do
    Integration.checkout!()
    Integration.cleanup!()
    actor = ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui)
    %{actor: actor, now: ~U[2026-03-07 00:00:00Z]}
  end

  test "migrations run and create the required tables against a real postgres instance" do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select tablename from pg_tables where schemaname = 'public' and tablename in ('alerts','alert_transitions','cases','case_timeline_entries','action_requests','audit_events') order by tablename",
        []
      )

    table_names = Enum.map(result.rows, &hd/1)

    assert table_names == [
             "action_requests",
             "alert_transitions",
             "alerts",
             "audit_events",
             "case_timeline_entries",
             "cases"
           ]
  end

  test "repo starts in db-backed mode when explicitly enabled" do
    status = Health.status()
    assert status.mode == :db_backed
    assert status.repo_enabled?
    assert status.repo_started?
  end

  test "alert persistence round trip works", %{actor: actor, now: now} do
    {:ok, alert, event} =
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

    assert {:ok, %{alert_insert: %AlertRecord{} = inserted}} =
             Alerts.persist_create(Repo, alert, event)

    assert inserted.alert_id == "alert-1"
    assert inserted.state == "open"

    {:ok, transitioned_alert, transition_event} =
      Alert.transition(
        alert,
        %TransitionAlert{
          alert_id: "alert-1",
          from_state: :open,
          to_state: :investigating,
          reason: "Investigation started",
          actor: actor
        },
        event_id: "evt-2",
        occurred_at: now
      )

    assert {:ok, %{alert_transition_insert: %AlertTransition{} = transition}} =
             Alerts.persist_transition(Repo, transitioned_alert, transition_event)

    persisted = Repo.get_by!(AlertRecord, alert_id: "alert-1")
    assert persisted.state == "investigating"
    assert transition.to_state == "investigating"
  end

  test "case persistence round trip works", %{actor: actor, now: now} do
    {:ok, case_record, event} =
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

    assert {:ok, %{case_insert: %CaseRecord{} = inserted_case}} =
             Cases.persist_open(Repo, case_record, event)

    assert inserted_case.case_id == "case-1"

    {:ok, triaged_case, transition_event} =
      InvestigationCase.transition(
        case_record,
        %TransitionCase{
          case_id: "case-1",
          from_status: :open,
          to_status: :triage,
          reason: "Initial triage",
          actor: actor
        },
        event_id: "evt-4",
        occurred_at: now
      )

    assert {:ok, %{case_timeline_insert: %CaseTimelineEntry{} = timeline_entry}} =
             Cases.persist_transition(Repo, triaged_case, transition_event)

    persisted = Repo.get_by!(CaseRecord, case_id: "case-1")
    assert persisted.status == "triage"
    assert timeline_entry.entry_type == "case_transitioned"
  end

  test "action request persistence round trip works", %{actor: actor, now: now} do
    {:ok, request, request_event} =
      ActionRequest.request(
        %RequestAction{
          action_request_id: "act-1",
          case_id: "case-1",
          action_class: :contain,
          target: "host-42",
          requested_by: actor,
          reason: "Contain host"
        },
        event_id: "evt-5",
        requested_at: now
      )

    assert {:ok, %{action_request_insert: %ActionRequestRecord{} = inserted}} =
             Actions.persist_request(Repo, request, request_event)

    assert inserted.action_request_id == "act-1"
    assert inserted.approval_status == "pending_approval"

    {:ok, approved, approve_event} =
      ActionRequest.approve(
        request,
        %ApproveAction{action_request_id: "act-1", approver: actor, reason: "Approved"},
        event_id: "evt-6",
        approved_at: now
      )

    assert {:ok, %{action_request_update: {1, _}}} =
             Actions.persist_approval(Repo, approved, approve_event)

    persisted = Repo.get_by!(ActionRequestRecord, action_request_id: "act-1")
    assert persisted.approval_status == "approved"
    assert persisted.approved_by == "analyst-1"
  end

  test "audit persistence round trip works", %{actor: actor, now: now} do
    event = %HacktuiCore.Events.AuditRecorded{
      event_id: "evt-7",
      audit_id: "audit-1",
      actor: actor,
      action: :approve_action,
      occurred_at: now,
      result: :allowed,
      subject: "act-1"
    }

    # Slice 40: the insert reports its outcome; the row is read back rather than returned.
    assert {:ok, %{audit_insert: {1, nil}, audit_outcome: :inserted}} =
             Audits.persist(Repo, event)

    inserted = Repo.get_by!(AuditEvent, audit_id: "audit-1")
    assert inserted.action == "approve_action"
    assert inserted.result == "allowed"
    # A non-observation audit row carries the enclave marking, never `{}`.
    assert inserted.marking["classification"] == "U"

    # The same audit_id again is REFUSED: only an observation's (source, fingerprint) is a
    # duplicate; a repeated audit_id is a caller defect and stays a loud error.
    assert {:error, :audit_insert, %Postgrex.Error{postgres: %{code: :unique_violation}}, _} =
             Audits.persist(Repo, event)

    assert Repo.aggregate(AuditEvent, :count, :id) == 1

    # An observation row re-delivered under the same identity IS a duplicate.
    observation = %HacktuiCore.Events.AuditRecorded{
      event
      | event_id: "evt-8",
        audit_id: "obs-8",
        action: :observation_accepted,
        subject: "obs-8",
        source: "sensor.test",
        fingerprint: "fp-8"
    }

    assert {:ok, %{audit_outcome: :inserted}} = Audits.persist(Repo, observation)

    assert {:ok, %{audit_insert: {0, nil}, audit_outcome: :duplicate}} =
             Audits.persist(Repo, %HacktuiCore.Events.AuditRecorded{
               observation
               | audit_id: "obs-8-again"
             })

    assert Repo.aggregate(AuditEvent, :count, :id) == 2
  end

  test "query service read models can read persisted data", %{actor: actor, now: now} do
    {:ok, alert, alert_event} =
      Alert.create(
        %CreateAlert{
          alert_id: "alert-9",
          title: "Read model alert",
          severity: :medium,
          observation_refs: ["obs-9"],
          actor: actor
        },
        event_id: "evt-9",
        occurred_at: now
      )

    {:ok, case_record, case_event} =
      InvestigationCase.open(
        %OpenCase{
          case_id: "case-9",
          title: "Read model case",
          source_alert_ids: ["alert-9"],
          actor: actor
        },
        event_id: "evt-10",
        opened_at: now
      )

    {:ok, request, request_event} =
      ActionRequest.request(
        %RequestAction{
          action_request_id: "act-9",
          case_id: "case-9",
          action_class: :contain,
          target: "host-99",
          requested_by: actor,
          reason: "Contain host"
        },
        event_id: "evt-11",
        requested_at: now
      )

    :ok = match?({:ok, _}, Alerts.persist_create(Repo, alert, alert_event)) && :ok
    :ok = match?({:ok, _}, Cases.persist_open(Repo, case_record, case_event)) && :ok
    :ok = match?({:ok, _}, Actions.persist_request(Repo, request, request_event)) && :ok

    cases = Repo.all(ReadModels.case_board_query())
    approvals = Repo.all(ReadModels.approval_inbox_query())
    timeline = Repo.all(ReadModels.case_timeline_query("case-9"))

    assert Enum.any?(cases, &(&1.case_id == "case-9"))
    assert Enum.any?(approvals, &(&1.action_request_id == "act-9"))
    assert Enum.any?(timeline, &(&1.case_id == "case-9"))
  end
end
