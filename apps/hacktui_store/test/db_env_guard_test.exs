defmodule HacktuiStore.DbEnvGuardTest do
  # Slice 39 guards, stated as measurements so a later edit cannot quietly reintroduce the
  # defect class: a test that sets :hacktui_store's :start_repo without going through
  # HacktuiTest.DbEnv has no restore by construction, and a second definition of the
  # environment contract is the two-copies-pass-a-grep-count hazard.
  use ExUnit.Case, async: false

  @umbrella Path.expand("../../..", __DIR__)
  @shared Path.join(@umbrella, "apps/hacktui_store/test/support/db_env.exs")

  # Built in two pieces so this file does not match its own needle.
  defp needle, do: "put_env(" <> ":hacktui_store, :start_repo"

  # One regex for "a definition of this function", used by the scan AND its positive control,
  # so a weakening of it (`\\b` after `!` never matches) fails the control rather than hiding.
  defp def_regex(fun), do: ~r/^\s*defp? #{Regex.escape(fun)}(\s*\(|\s*,|\s+do\b|\s*$)/m

  defp test_files do
    @umbrella
    |> Path.join("apps/*/test/**/*.exs")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == @shared))
  end

  test "no test file sets :start_repo directly; every setter goes through HacktuiTest.DbEnv" do
    offenders =
      for f <- test_files(),
          String.contains?(File.read!(f), needle()),
          do: Path.relative_to(f, @umbrella)

    assert offenders == [],
           "direct :start_repo setters in tests (no restore by construction): #{inspect(offenders)}"
  end

  test "positive control: the shared module is the one place that sets the key" do
    assert File.read!(@shared) =~ "Application.put_env(@app, @key, value)"
  end

  test "db_env/0, require_db_env!/0, start_repo!/0 and stop_repo!/0 have exactly one definition" do
    defs =
      for f <- test_files(),
          body = File.read!(f),
          fun <- ~w(db_env require_db_env! start_repo! stop_repo!),
          body =~ def_regex(fun),
          do: {fun, Path.relative_to(f, @umbrella)}

    assert defs == [], "second definitions found (delegate instead): #{inspect(defs)}"

    # Positive control for every name, including the bang ones: the regex must see a
    # definition when one exists. (`\b` after `!` never matches, which hid three names once.)
    for fun <- ~w(db_env require_db_env! start_repo! stop_repo!), kw <- ~w(def defp) do
      assert "  #{kw} #{fun} do\n" =~ def_regex(fun),
             "the one-definition regex is blind to `#{kw} #{fun}`"
    end
  end

  test "every integration module carries the conditional skip tag" do
    modules =
      for f <- test_files(), String.contains?(File.read!(f), "@moduletag :integration"), do: f

    refute modules == [], "positive control: at least one integration module exists"

    untagged =
      for f <- modules,
          not String.contains?(File.read!(f), "@moduletag skip: reason"),
          do: Path.relative_to(f, @umbrella)

    assert untagged == [], "integration modules that raise instead of skip: #{inspect(untagged)}"
  end

  test "restore is exact for a present key, and the absent branch deletes rather than writes nil" do
    # In the test environment config/test.exs makes the key present (false). A set/restore
    # pair must hand back exactly that value. The absent branch is asserted on the source:
    # writing `nil` back (the old unit tests did) would make an absent key "present and nil".
    before = Application.fetch_env(:hacktui_store, :start_repo)
    assert {:ok, _} = before

    HacktuiTest.DbEnv.set_start_repo!(true)
    assert Application.fetch_env(:hacktui_store, :start_repo) == {:ok, true}
    HacktuiTest.DbEnv.restore_start_repo!()
    assert Application.fetch_env(:hacktui_store, :start_repo) == before

    assert File.read!(@shared) =~ ":error -> Application.delete_env(@app, @key)"
    refute File.read!(@shared) =~ "put_env(@app, @key, nil)"
  end
end
