defmodule HacktuiAgent.AgentDbSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Slice 39: without the database environment this module SKIPS with a reason. It never
  # raises in setup_all, which ExUnit reports as "invalid" -- a word a grep for "failures"
  # reads as green. CI asserts skipped == 0, so a run without the environment is red there.
  case HacktuiTest.DbEnv.db_env() do
    :ok -> :ok
    {:skip, reason} -> @moduletag skip: reason
  end

  alias HacktuiAgent.Health
  alias HacktuiAgent.TestSupport.Integration

  setup_all do
    Integration.require_db_env!()
    Application.put_env(:hacktui_agent, :enabled_backends, [:jido])
    Integration.start_repo!()
    Integration.migrate!()
    {:ok, _} = Application.ensure_all_started(:hacktui_hub)

    if Process.whereis(HacktuiAgent.Supervisor) do
      Application.stop(:hacktui_agent)
    end

    {:ok, _} = Application.ensure_all_started(:hacktui_agent)

    on_exit(fn ->
      Application.put_env(:hacktui_agent, :enabled_backends, [])
      Application.stop(:hacktui_agent)
      Application.stop(:hacktui_hub)
      Integration.stop_repo!()
    end)

    :ok
  end

  test "db-backed + agent-enabled mode health is explicit" do
    status = Health.status()
    assert status.mode == :jido_enabled
    assert status.enabled?
    assert status.jido_enabled?
    assert status.jido_instance_started?
  end
end
