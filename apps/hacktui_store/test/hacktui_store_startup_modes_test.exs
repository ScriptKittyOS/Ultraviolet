defmodule HacktuiStore.StartupModesTest do
  use ExUnit.Case, async: false

  alias HacktuiStore.Health

  setup do
    on_exit(fn -> HacktuiTest.DbEnv.restore_start_repo!() end)

    :ok
  end

  test "reports safe no-repo mode by default" do
    HacktuiTest.DbEnv.set_start_repo!(false)

    assert %{mode: :safe_no_repo, repo_enabled?: false, repo_started?: false} = Health.status()
  end

  test "reports degraded mode when repo startup is enabled but the repo is not started" do
    HacktuiTest.DbEnv.set_start_repo!(true)

    assert %{
             mode: {:degraded, :repo_not_started},
             repo_enabled?: true,
             repo_started?: false,
             repo_connectivity: :repo_not_started
           } = Health.status()
  end

  test "supervisor child list includes repo only when enabled" do
    HacktuiTest.DbEnv.set_start_repo!(false)
    {:ok, {_flags, children}} = HacktuiStore.Supervisor.init([])
    refute Enum.any?(children, &match?(%{id: HacktuiStore.Repo}, &1))

    HacktuiTest.DbEnv.set_start_repo!(true)
    {:ok, {_flags, children}} = HacktuiStore.Supervisor.init([])
    assert Enum.any?(children, &match?(%{id: HacktuiStore.Repo}, &1))
  end
end
