# One definition of the integration-test environment contract, shared by every umbrella app's
# test_helper.exs via Code.require_file. It answers two questions the suite used to answer
# inconsistently: "is the database environment present?" and "who restores :start_repo?".
#
# Skip, not raise: when HACKTUI_DB_PASS is absent, an integration module tags itself
# `@moduletag skip: reason`, so a local run reads "N skipped" -- never "0 failures, N invalid",
# which a grep for "failures" reads as green. ExUnit's formatter does not print a skip reason;
# it is carried on the tag (measured in review). CI separately asserts that skipped == 0, so a
# run without the environment is red at the job level.
#
# Restore, not merely stop: every setter of :hacktui_store's :start_repo goes through this
# module, which captures the previous value and restores it exactly -- put_env when a value
# existed, delete_env when none did. An absent key and an explicit false are different
# postures since slice 38; a restore must not collapse them.
unless Code.ensure_loaded?(HacktuiTest.DbEnv) do
  defmodule HacktuiTest.DbEnv do
    @app :hacktui_store
    @key :start_repo
    @slot {__MODULE__, :previous_start_repo}

    @doc "`:ok` when the integration environment is present, `{:skip, reason}` when it is not."
    @spec db_env() :: :ok | {:skip, String.t()}
    def db_env do
      case System.get_env("HACKTUI_DB_PASS") do
        v when v in [nil, ""] ->
          {:skip,
           "integration qualification skipped: HACKTUI_DB_PASS is unset " <>
             "(source .env, or export the HACKTUI_DB_* variables)"}

        _ ->
          :ok
      end
    end

    @doc "Raises with the skip reason. Only reachable if a module called it without the tag."
    @spec require_db_env!() :: :ok
    def require_db_env! do
      case db_env() do
        :ok -> :ok
        {:skip, reason} -> raise reason
      end
    end

    @doc """
    Sets `:start_repo` and remembers what it replaced. Nested calls keep the OUTERMOST
    previous value, so a module that sets the key twice still restores what it found.
    """
    @spec set_start_repo!(boolean()) :: :ok
    def set_start_repo!(value) when is_boolean(value) do
      if :persistent_term.get(@slot, :unset) == :unset do
        :persistent_term.put(@slot, Application.fetch_env(@app, @key))
      end

      Application.put_env(@app, @key, value)
      :ok
    end

    @doc "Restores `:start_repo` to exactly what `set_start_repo!/1` found, and forgets it."
    @spec restore_start_repo!() :: :ok
    def restore_start_repo! do
      case :persistent_term.get(@slot, :unset) do
        :unset -> :ok
        {:ok, previous} -> Application.put_env(@app, @key, previous)
        :error -> Application.delete_env(@app, @key)
      end

      :persistent_term.erase(@slot)
      :ok
    end

    @doc "Stops a running store, enables the repo, starts the store. Pairs with `stop_repo!/0`."
    @spec start_repo!() :: :ok
    def start_repo! do
      if Application.spec(@app, :modules) && Process.whereis(HacktuiStore.Supervisor) do
        Application.stop(@app)
      end

      set_start_repo!(true)
      {:ok, _} = Application.ensure_all_started(@app)
      :ok
    end

    @doc "Stops the store AND restores `:start_repo`. The old version only stopped."
    @spec stop_repo!() :: :ok
    def stop_repo! do
      Application.stop(@app)
      restore_start_repo!()
    end
  end
end
