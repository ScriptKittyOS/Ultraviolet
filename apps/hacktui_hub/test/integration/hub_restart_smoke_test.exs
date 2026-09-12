defmodule HacktuiHub.HubRestartSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  alias HacktuiHub.Health
  alias HacktuiHub.TestSupport.Integration

  setup_all do
    Integration.require_db_env!()
    Integration.start_repo!()
    Integration.migrate!()

    on_exit(fn ->
      if Process.whereis(HacktuiHub.Supervisor), do: Application.stop(:hacktui_hub)
      Integration.stop_repo!()
    end)

    :ok
  end

  setup do
    Integration.checkout!()
    :ok
  end

  test "db-backed hub mode can start, stop, and start again cleanly" do
    {:ok, _} = Application.ensure_all_started(:hacktui_hub)
    assert Health.status().store.mode == :db_backed
    assert Health.status().hub.supervisor_started?

    :ok = Application.stop(:hacktui_hub)
    refute Process.whereis(HacktuiHub.Supervisor)

    {:ok, _} = Application.ensure_all_started(:hacktui_hub)
    assert Health.status().store.mode == :db_backed
    assert Health.status().hub.supervisor_started?
  end
end
