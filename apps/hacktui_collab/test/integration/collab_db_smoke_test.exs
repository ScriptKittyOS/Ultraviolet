defmodule HacktuiCollab.CollabDbSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  alias HacktuiCollab.Health
  alias HacktuiCollab.TestSupport.Integration
  alias HacktuiHub.Health, as: HubHealth

  setup_all do
    Integration.require_db_env!()
    Application.put_env(:hacktui_collab, :enabled_providers, [:slack])
    Integration.start_repo!()
    Integration.migrate!()
    {:ok, _} = Application.ensure_all_started(:hacktui_hub)

    if Process.whereis(HacktuiCollab.Supervisor) do
      Application.stop(:hacktui_collab)
    end

    {:ok, _} = Application.ensure_all_started(:hacktui_collab)

    on_exit(fn ->
      Application.put_env(:hacktui_collab, :enabled_providers, [])
      Application.stop(:hacktui_collab)
      Application.stop(:hacktui_hub)
      Integration.stop_repo!()
    end)

    :ok
  end

  setup do
    HacktuiCollab.TestSupport.Integration.checkout!()
    HacktuiCollab.TestSupport.Integration.cleanup!()
    :ok
  end

  test "db-backed + collab mode reports explicit enabled and disabled boundaries" do
    collab = Health.status()
    hub = HubHealth.status()

    assert collab.mode == :enabled
    assert collab.enabled?
    assert collab.enabled_providers == [:slack]

    assert hub.store.mode == :db_backed
    assert hub.collab.mode == :enabled
    assert hub.agent.mode == :disabled
  end
end
