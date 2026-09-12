defmodule HacktuiCore.CiIntegrationSummaryTest do
  # The CI integration job (slice 39) calls tools/ci/integration_gate.sh, which refuses a run in
  # which any test was skipped or invalid. This test runs THAT SCRIPT, not a paraphrase of it,
  # under `bash --noprofile --norc -eo pipefail` -- stricter than the workflow's unspecified
  # shell (`bash -e {0}`) -- because a first version of the step was red on every outcome under
  # `-e` and a regex re-implemented in Elixir could not have seen it. `run` mode is exercised
  # with a stub `mix` on PATH, because `check` mode alone cannot reach the `mix test` line.
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @script Path.join(@root, "tools/ci/integration_gate.sh")
  @fixtures Path.join(@root, "apps/hacktui_core/test/fixtures/ci")
  @ci Path.join(@root, ".github/workflows/ci.yml")

  defp gate(fixture, test_rc) do
    System.cmd(
      "bash",
      [
        "--noprofile",
        "--norc",
        "-eo",
        "pipefail",
        @script,
        "check",
        Path.join(@fixtures, fixture),
        test_rc
      ],
      stderr_to_stdout: true
    )
  end

  test "a clean summary with a passing test rc passes, and prints its counts" do
    assert {out, 0} = gate("integration-clean.out", "0")
    assert out =~ "integration: rc=0 skipped=0 invalid=0"
  end

  test "two skipped across apps is refused with a named error" do
    assert {out, 1} = gate("integration-2-skipped.out", "0")
    assert out =~ "::error::2 integration tests skipped"
  end

  test "eight invalid is refused with a named error" do
    assert {out, 1} = gate("integration-8-invalid.out", "0")
    assert out =~ "::error::8 integration tests invalid"
  end

  test "a clean summary still returns the test's own non-zero exit code" do
    assert {out, 2} = gate("integration-clean.out", "2")
    assert out =~ "integration: rc=2"
  end

  # `run` mode: a stub `mix` first on PATH prints a fixture and exits with STUB_RC. With
  # errexit forced on (the invocation below), a script whose `mix test` line is not protected
  # aborts before echoing the output or printing a diagnostic -- the mutant `set +e` -> `set -e`.
  defp run_mode(fixture, stub_rc) do
    dir = Path.join(System.tmp_dir!(), "uv-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    stub = Path.join(dir, "bin/mix")

    File.write!(stub, """
    #!/usr/bin/env bash
    cat "#{Path.join(@fixtures, fixture)}"
    exit #{stub_rc}
    """)

    File.chmod!(stub, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)

    System.cmd(
      "bash",
      ["--noprofile", "--norc", "-eo", "pipefail", @script, "run"],
      cd: dir,
      env: [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end

  test "run mode: a failing mix test still echoes the output and returns the test's rc" do
    assert {out, 2} = run_mode("integration-clean.out", 2)
    assert out =~ "94 tests, 0 failures"
    assert out =~ "integration: rc=2 skipped=0 invalid=0"
  end

  test "run mode: invalid tests are refused with the diagnostic even when mix test fails" do
    assert {out, 1} = run_mode("integration-8-invalid.out", 2)
    assert out =~ "::error::8 integration tests invalid"
  end

  test "run mode: a clean passing run exits 0 and leaves no integration.out behind" do
    assert {out, 0} = run_mode("integration-clean.out", 0)
    assert out =~ "integration: rc=0 skipped=0 invalid=0"
  end

  test "the workflow calls the script; the skip change does not ship without the gate" do
    assert File.read!(@ci) =~ "./tools/ci/integration_gate.sh run"
  end
end
