defmodule HacktuiStore.RuntimeExsStartRepoTest do
  # Exercises config/runtime.exs itself, not only the parser it calls, so the wiring between
  # `HacktuiStore.RuntimeConfig.start_repo_setting/1`, the `start_repo` boolean and the
  # production validator has a red of its own. Without this file a mutant such as
  # `start_repo = start_repo_setting != :absent` (explicit false starts the repo) survives the
  # unit suite and is caught only by a container run.
  #
  # `async: false`: it mutates the process environment.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)
  @var "HACKTUI_START_REPO"
  @db_vars ~w(HACKTUI_DB_USER HACKTUI_DB_PASS HACKTUI_DB_HOST HACKTUI_DB_PORT HACKTUI_DB_NAME)

  setup do
    saved = for v <- [@var | @db_vars], into: %{}, do: {v, System.get_env(v)}
    for v <- Map.keys(saved), do: System.delete_env(v)

    on_exit(fn ->
      for {v, val} <- saved do
        if val, do: System.put_env(v, val), else: System.delete_env(v)
      end
    end)

    :ok
  end

  defp read_prod, do: Config.Reader.read!(@runtime_exs, env: :prod)
  defp start_repo(cfg), do: get_in(cfg, [:hacktui_store, :start_repo])

  test "prod: explicit false boots with start_repo false and no database variables at all" do
    System.put_env(@var, "false")
    assert start_repo(read_prod()) == false
  end

  test "prod: absent refuses, naming both choices" do
    error = assert_raise RuntimeError, fn -> read_prod() end
    assert error.message =~ "HACKTUI_START_REPO must be set explicitly in production"
    assert error.message =~ "false to boot in safe mode"
  end

  test "prod: true with the demo defaults refuses on the credentials, not on start_repo" do
    System.put_env(@var, "true")
    error = assert_raise RuntimeError, fn -> read_prod() end
    assert error.message =~ "cannot use the default demo"
    refute error.message =~ "must be set explicitly"
  end

  test "prod: true with real values starts the repo" do
    System.put_env(@var, "true")

    for {v, val} <- Enum.zip(@db_vars, ~w(app_user s3cret db.internal 5432 hacktui_prod)),
        do: System.put_env(v, val)

    assert start_repo(read_prod()) == true
  end

  test "dev: absent still means false, as before" do
    assert start_repo(Config.Reader.read!(@runtime_exs, env: :dev)) == false
  end
end
