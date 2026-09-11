defmodule HacktuiStore.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias HacktuiStore.RuntimeConfig

  describe "production_repo_config_errors/2" do
    # Slice 38: absence is the error, not `false`. An operator who never set the variable is
    # told both valid choices and what each means -- the refusal is Tier 0's first impression.
    test "rejects an ABSENT start_repo setting in production, naming both choices" do
      repo_config = [
        username: "prod_user",
        password: "super-secret",
        hostname: "postgres.internal",
        port: 5432,
        database: "hacktui_prod"
      ]

      assert [message] = RuntimeConfig.production_repo_config_errors(:absent, repo_config)
      assert message =~ "HACKTUI_START_REPO must be set explicitly in production"
      assert message =~ "true"
      assert message =~ "false"
      assert message =~ "safe mode"
    end

    # Slice 38: explicit `false` is a supported production posture (safe_no_repo). No
    # credential is checked, because nothing will connect -- even demo defaults are fine here.
    test "explicit false in production is safe mode: no errors, credentials not consulted" do
      demo_defaults = [
        username: "hacktui",
        password: "postgres",
        hostname: "localhost",
        port: 5432,
        database: "hacktui_qualification_test"
      ]

      assert RuntimeConfig.production_repo_config_errors(false, demo_defaults) == []
      assert RuntimeConfig.production_repo_config_errors(false, :not_a_keyword_list) == []
    end

    test "rejects demo defaults in production" do
      repo_config = [
        username: "hacktui",
        password: "postgres",
        hostname: "localhost",
        port: 5432,
        database: "hacktui_qualification_test"
      ]

      assert RuntimeConfig.production_repo_config_errors(true, repo_config) == [
               "HACKTUI_DB_NAME cannot use the qualification/demo database",
               "HACKTUI_DB_USER cannot use the default demo username",
               "HACKTUI_DB_PASS cannot use the default demo password",
               "HACKTUI_DB_HOST cannot default to localhost in production"
             ]
    end

    test "accepts explicit non-demo production configuration" do
      repo_config = [
        username: "hacktui_app",
        password: "correct-horse-battery-staple",
        hostname: "postgres.service.consul",
        port: 5432,
        database: "hacktui_prod"
      ]

      assert RuntimeConfig.production_repo_config_errors(true, repo_config) == []
    end
  end

  # Slice 38: the three-way reading of the environment lives here, not in config/runtime.exs,
  # so it can be tested. `System.fetch_env/1` is the only call under which an absent variable
  # and an explicit "false" are different values; `get_env/2` with a default collapses them.
  describe "start_repo_setting/1" do
    test "absent is :absent" do
      assert RuntimeConfig.start_repo_setting(:error) == :absent
    end

    test "set but empty is :absent -- an empty string is not a statement" do
      assert RuntimeConfig.start_repo_setting({:ok, ""}) == :absent
      assert RuntimeConfig.start_repo_setting({:ok, "   "}) == :absent
    end

    test "explicit falsy values are false" do
      for v <- ["false", "0", "no", "off", "FALSE", " False "] do
        assert RuntimeConfig.start_repo_setting({:ok, v}) == false,
               "expected false for #{inspect(v)}"
      end
    end

    test "explicit truthy values are true" do
      for v <- ["true", "1", "yes", "on", "TRUE"] do
        assert RuntimeConfig.start_repo_setting({:ok, v}) == true,
               "expected true for #{inspect(v)}"
      end
    end

    test "anything else is :absent -- a typo must not silently mean false" do
      assert RuntimeConfig.start_repo_setting({:ok, "fals"}) == :absent
      assert RuntimeConfig.start_repo_setting({:ok, "maybe"}) == :absent
    end
  end
end
