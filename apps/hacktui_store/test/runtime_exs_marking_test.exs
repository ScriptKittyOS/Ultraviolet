defmodule HacktuiStore.RuntimeExsMarkingTest do
  # Slice 40: `HACKTUI_MARKING` is read the same three ways as `HACKTUI_START_REPO` (slice 38):
  # absent in production refuses at config time and names the variable and its choices; an
  # explicit value is the enclave marking every unmarked observation inherits; dev/test default
  # to "U". Exercises config/runtime.exs itself, so the wiring has a red of its own.
  #
  # `async: false`: it mutates the process environment.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)
  @vars ~w(HACKTUI_MARKING HACKTUI_START_REPO HACKTUI_DB_USER HACKTUI_DB_PASS HACKTUI_DB_HOST
           HACKTUI_DB_PORT HACKTUI_DB_NAME)

  setup do
    saved = for v <- @vars, into: %{}, do: {v, System.get_env(v)}
    for v <- Map.keys(saved), do: System.delete_env(v)
    # Safe mode, so the only thing left to refuse is the marking.
    System.put_env("HACKTUI_START_REPO", "false")

    on_exit(fn ->
      for {v, val} <- saved do
        if val, do: System.put_env(v, val), else: System.delete_env(v)
      end
    end)

    :ok
  end

  defp read(env), do: Config.Reader.read!(@runtime_exs, env: env)
  defp marking(cfg), do: get_in(cfg, [:hacktui_core, :enclave_marking])

  test "prod: absent refuses at config time, naming the variable and its choices" do
    error = assert_raise RuntimeError, fn -> read(:prod) end
    assert error.message =~ "HACKTUI_MARKING must be set explicitly in production"
    assert error.message =~ "U, C, S or TS"
    refute error.message =~ "HACKTUI_START_REPO"
  end

  test "prod: an explicit banner is the enclave marking, source :explicit" do
    System.put_env("HACKTUI_MARKING", "S//NOFORN")

    assert marking(read(:prod)) == %{
             classification: "S",
             owner_producer: [],
             dissemination_controls: ["NOFORN"],
             source: :explicit
           }
  end

  test "prod: a banner with a control byte or too many controls refuses at config time" do
    for banner <- ["S//NO\e[2JFORN", "U//" <> Enum.join(List.duplicate("X", 33), "/")] do
      System.put_env("HACKTUI_MARKING", banner)
      error = assert_raise RuntimeError, fn -> read(:prod) end
      assert error.message =~ "HACKTUI_MARKING is not a valid banner"
    end
  end

  test "prod: an unrecognised classification refuses, naming the choices" do
    System.put_env("HACKTUI_MARKING", "SECRET")
    error = assert_raise RuntimeError, fn -> read(:prod) end
    assert error.message =~ "HACKTUI_MARKING"
    assert error.message =~ "U, C, S or TS"
  end

  test "dev: an explicit malformed value is refused, not replaced by U" do
    System.put_env("HACKTUI_MARKING", "SECRET")
    error = assert_raise RuntimeError, fn -> read(:dev) end
    assert error.message =~ "HACKTUI_MARKING"
    assert error.message =~ "U, C, S or TS"
  end

  test "dev: absent defaults to U, source :enclave_default" do
    assert marking(read(:dev)) == %{
             classification: "U",
             owner_producer: [],
             dissemination_controls: [],
             source: :enclave_default
           }
  end
end
