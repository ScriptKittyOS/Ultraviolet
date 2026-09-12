defmodule HacktuiStore.HealthProductionTest do
  use ExUnit.Case, async: false

  alias HacktuiStore.Health

  setup do
    original_repo_config = Application.get_env(:hacktui_store, HacktuiStore.Repo)

    on_exit(fn ->
      HacktuiTest.DbEnv.restore_start_repo!()

      if is_nil(original_repo_config) do
        Application.delete_env(:hacktui_store, HacktuiStore.Repo)
      else
        Application.put_env(:hacktui_store, HacktuiStore.Repo, original_repo_config)
      end
    end)

    :ok
  end

  test "reports production configuration blockers for demo defaults" do
    HacktuiTest.DbEnv.set_start_repo!(true)

    Application.put_env(:hacktui_store, HacktuiStore.Repo,
      username: "hacktui",
      password: "postgres",
      hostname: "localhost",
      port: 5432,
      database: "hacktui_qualification_test"
    )

    status = Health.status()

    assert status.production_configuration_ready? == false

    assert "HACKTUI_DB_NAME cannot use the qualification/demo database" in status.repo_configuration_errors

    assert "HACKTUI_DB_PASS cannot use the default demo password" in status.repo_configuration_errors
  end

  test "reports production configuration ready for explicit non-demo config" do
    HacktuiTest.DbEnv.set_start_repo!(true)

    Application.put_env(:hacktui_store, HacktuiStore.Repo,
      username: "hacktui_app",
      password: "super-secret",
      hostname: "postgres.internal",
      port: 5432,
      database: "hacktui_prod"
    )

    status = Health.status()

    assert status.production_configuration_ready? == true
    assert status.repo_configuration_errors == []
  end
end
