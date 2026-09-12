defmodule HacktuiStore.DbUnavailableTest do
  use ExUnit.Case, async: false

  setup do
    previous_repo_config = Application.get_env(:hacktui_store, HacktuiStore.Repo)

    on_exit(fn ->
      HacktuiTest.DbEnv.restore_start_repo!()
      Application.put_env(:hacktui_store, HacktuiStore.Repo, previous_repo_config)

      if Process.whereis(HacktuiStore.Supervisor) do
        Application.stop(:hacktui_store)
      end
    end)

    :ok
  end

  test "db-backed startup fails explicitly when repo is enabled but db is unavailable" do
    if Process.whereis(HacktuiStore.Supervisor) do
      Application.stop(:hacktui_store)
    end

    HacktuiTest.DbEnv.set_start_repo!(true)

    Application.put_env(
      :hacktui_store,
      HacktuiStore.Repo,
      Application.get_env(:hacktui_store, HacktuiStore.Repo, [])
      |> Keyword.put(:hostname, "127.0.0.1")
      |> Keyword.put(:port, 65432)
      |> Keyword.put(:connect_timeout, 200)
      |> Keyword.put(:pool_size, 1)
    )

    assert {:ok, _} = Application.ensure_all_started(:hacktui_store)

    assert_raise DBConnection.ConnectionError, fn ->
      Ecto.Adapters.SQL.query!(HacktuiStore.Repo, "select 1", [], timeout: 500)
    end
  end
end
