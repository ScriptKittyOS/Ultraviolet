defmodule HacktuiAgent.InvestigationFlowDbIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  alias HacktuiAgent.InvestigationFlow
  alias HacktuiAgent.TestSupport.Integration
  alias HacktuiStore.{DemoDatabase, DemoSeed, Repo}
  alias HacktuiStore.Schema.{Alert, CaseRecord, CaseTimelineEntry}

  setup_all do
    Integration.require_db_env!()
    DemoDatabase.ensure_ready!()
    :ok
  end

  setup do
    DemoSeed.seed_case_1!()
    :ok
  end

  test "seed_case_1!/0 uses fixed demo timestamps" do
    assert [%Alert{inserted_at: inserted_at, updated_at: updated_at} | _] =
             Repo.all(Alert)

    assert %CaseRecord{inserted_at: case_inserted_at, updated_at: case_updated_at} =
             Repo.get_by!(CaseRecord, case_id: "case-1")

    assert [
             %CaseTimelineEntry{entry_type: "case_opened", occurred_at: opened_at},
             %CaseTimelineEntry{entry_type: "alert_linked", occurred_at: linked_at}
           ] =
             Repo.all(from(entry in CaseTimelineEntry, order_by: [asc: entry.occurred_at]))

    assert inserted_at == ~U[2026-03-07 13:00:00.000000Z]
    assert updated_at == ~U[2026-03-07 13:00:00.000000Z]
    assert case_inserted_at == ~U[2026-03-07 13:00:00.000000Z]
    assert case_updated_at == ~U[2026-03-07 13:00:00.000000Z]
    assert opened_at == ~U[2026-03-07 13:00:00.000000Z]
    assert linked_at == ~U[2026-03-07 13:00:10.000000Z]

    # Slice 40: seeded rows are marked like any other row (insert_all bypasses the changeset).
    for %Alert{marking: marking} <- Repo.all(Alert), do: assert(marking["classification"] == "U")
    assert Repo.get_by!(CaseRecord, case_id: "case-1").marking["classification"] == "U"
  end

  test "run/1 works against the real local db-backed runtime with seeded demo data" do
    assert {:ok, agent, _directives} = InvestigationFlow.run("case-1")
    assert agent.state.case_id == "case-1"
    assert agent.state.correlation.matched_alert_ids == ["alert-1", "alert-2"]
    assert agent.state.correlation.shared_indicators == ["10.0.0.4", "malicious.example"]
    assert agent.state.report_draft.summary =~ "case-1"
  end

  test "run/2 accepts nil opts" do
    assert {:ok, agent, _directives} = InvestigationFlow.run("case-1", nil)
    assert agent.state.case_id == "case-1"
  end

  test "run/2 accepts keyword opts" do
    assert {:ok, agent, _directives} = InvestigationFlow.run("case-1", [])
    assert agent.state.case_id == "case-1"
  end

  test "run/2 accepts map opts" do
    assert {:ok, agent, _directives} = InvestigationFlow.run("case-1", %{})
    assert agent.state.case_id == "case-1"
  end
end
