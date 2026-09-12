defmodule HacktuiHub.HubDbIntegrationTest do
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
  alias HacktuiCore.Commands.{CreateAlert, OpenCase, RequestAction}
  alias HacktuiHub.{Health, QueryService, Runtime}
  alias HacktuiStore.Repo
  alias HacktuiHub.TestSupport.Integration

  setup_all do
    Integration.require_db_env!()
    Integration.start_repo!()
    Integration.migrate!()
    {:ok, _} = Application.ensure_all_started(:hacktui_hub)

    on_exit(fn ->
      Application.stop(:hacktui_hub)
      Integration.stop_repo!()
    end)

    :ok
  end

  setup do
    Integration.checkout!()
    Integration.cleanup!()
    actor = ActorRef.new!(id: "analyst-1", type: :human, role: :analyst, source: :tui)
    %{actor: actor, now: ~U[2026-03-07 00:00:00Z]}
  end

  test "hub -> store -> read-model round trip works", %{actor: actor, now: now} do
    assert {:ok, alert_result} =
             Runtime.create_alert(
               %CreateAlert{
                 alert_id: "alert-1",
                 title: "Hub alert",
                 severity: :high,
                 observation_refs: ["obs-1"],
                 actor: actor
               },
               repo: Repo,
               event_id: "evt-1",
               occurred_at: now
             )

    assert {:ok, case_result} =
             Runtime.open_case(
               %OpenCase{
                 case_id: "case-1",
                 title: "Hub case",
                 source_alert_ids: [alert_result.aggregate.alert_id],
                 actor: actor
               },
               repo: Repo,
               event_id: "evt-2",
               opened_at: now
             )

    assert {:ok, action_result} =
             Runtime.request_action(
               %RequestAction{
                 action_request_id: "act-1",
                 case_id: case_result.aggregate.case_id,
                 action_class: :contain,
                 target: "host-42",
                 requested_by: actor,
                 reason: "Contain host"
               },
               repo: Repo,
               event_id: "evt-3",
               requested_at: now
             )

    assert {:ok, _audit_result} =
             Runtime.record_audit(
               :request_action,
               actor,
               repo: Repo,
               event_id: "evt-4",
               audit_id: "audit-1",
               occurred_at: now,
               result: :allowed,
               subject: action_result.aggregate.action_request_id
             )

    assert Enum.any?(QueryService.alert_queue(Repo), &(&1.alert_id == "alert-1"))
    assert Enum.any?(QueryService.case_board(Repo), &(&1.case_id == "case-1"))
    assert Enum.any?(QueryService.approval_inbox(Repo), &(&1.action_request_id == "act-1"))
    assert Enum.any?(QueryService.audit_events(Repo), &(&1.audit_id == "audit-1"))
    assert Enum.any?(QueryService.case_timeline(Repo, "case-1"), &(&1.case_id == "case-1"))
  end

  test "db-backed + hub mode health is explicit" do
    status = Health.status()
    assert status.store.mode == :db_backed
    assert status.store.repo_enabled?
    assert status.hub.supervisor_started?
  end
end
