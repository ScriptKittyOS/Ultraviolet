# One definition of db_env/0, require_db_env!/0, start_repo!/0 and stop_repo!/0 for every app
# (slice 39). The four copies this replaced were byte-identical and restored nothing.
Code.require_file(Path.expand("../../hacktui_store/test/support/db_env.exs", __DIR__))

defmodule HacktuiCollab.TestSupport.Integration do
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias HacktuiStore.Repo

  @tables [
    "alert_transitions",
    "alerts",
    "case_timeline_entries",
    "cases",
    "action_requests",
    "audit_events"
  ]

  # Slice 39: one definition, in apps/hacktui_store/test/support/db_env.exs.
  defdelegate db_env(), to: HacktuiTest.DbEnv
  defdelegate require_db_env!(), to: HacktuiTest.DbEnv
  defdelegate start_repo!(), to: HacktuiTest.DbEnv
  defdelegate stop_repo!(), to: HacktuiTest.DbEnv

  @spec migrate!() :: [term()]
  def migrate! do
    migrations_path = Path.join(to_string(:code.priv_dir(:hacktui_store)), "repo/migrations")

    with_auto_mode(fn ->
      {:ok, _pid, result} =
        Ecto.Migrator.with_repo(Repo, fn repo ->
          Ecto.Migrator.run(repo, migrations_path, :up, all: true, log: false)
        end)

      result
    end)
  end

  @spec checkout!() :: :ok
  def checkout! do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  @spec cleanup!() :: :ok
  def cleanup! do
    truncate_tables!()
    :ok
  end

  @spec migration_statuses() :: [tuple()]
  def migration_statuses do
    {:ok, _pid, result} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.migrations/1)
    result
  end

  defp truncate_tables! do
    SQL.query!(Repo, "TRUNCATE TABLE #{Enum.join(@tables, ", ")} RESTART IDENTITY CASCADE", [])
    :ok
  end

  defp with_auto_mode(fun) do
    Sandbox.mode(Repo, :auto)

    try do
      fun.()
    after
      Sandbox.mode(Repo, :manual)
    end
  end
end

ExUnit.start(exclude: [integration: true])
