defmodule HacktuiStore.StoreDbResetCycleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  alias HacktuiStore.TestSupport.Integration

  setup_all do
    Integration.require_db_env!()
    Integration.start_repo!()
    Integration.migrate!()

    on_exit(fn ->
      Integration.stop_repo!()
    end)

    :ok
  end

  test "qualification db can be reset and migrated again" do
    before_reset = Integration.public_tables!()
    assert "alerts" in before_reset
    assert "cases" in before_reset

    :ok = Integration.reset_schema!()
    after_reset = Integration.public_tables!()
    assert after_reset == []

    _ = Integration.migrate!()
    after_migrate = Integration.public_tables!()
    assert "alerts" in after_migrate
    assert "cases" in after_migrate
    assert "action_requests" in after_migrate
    assert "audit_events" in after_migrate
  end
end
