#!/usr/bin/env bash
# Runs the DB-backed integration suite and refuses a run in which any test was skipped or
# invalid. "0 failures, N skipped" is the false green this project keeps filing: the modules
# skip with a reason when the database environment is absent, so a misconfigured job would
# otherwise read as clean.
#
# GitHub runs unspecified-shell steps under `bash -e {0}` and `shell: bash` steps under
# `-eo pipefail`. The step this script replaced ran `grep | awk` in the main shell, so on a clean
# run `grep -oE` exited 1, pipefail carried it through `| awk`, and errexit fired on the
# assignment: red on every outcome, no diagnostic. Two things protect this script: the counting
# happens inside a `$(...)` substitution (bash does not inherit errexit there), and `set +e`
# below covers the one line that is NOT inside a substitution -- the `mix test` invocation in
# `run` mode. That line is load-bearing: with `set -e`, a failing `mix test` aborts before the
# output is echoed and before any diagnostic (measured with a stub `mix`; the mutant row
# `s39_ci_errexit_off` and the run-mode test exist because a first version of this header
# claimed the opposite from `check`-mode measurements alone).
#
# Usage:
#   tools/ci/integration_gate.sh run              # mix test --include integration, then check
#   tools/ci/integration_gate.sh check <out> <rc> # check a captured summary + test exit code
set +e
set -u

mode="${1:?usage: integration_gate.sh run | check <out> <rc>}"

count() {  # sum of "<n> <word>" across the per-app summary lines; 0 when the word is absent
  local word="$1" file="$2" n
  n=$(grep -oE "[0-9]+ ${word}" "$file" | awk '{s+=$1} END{print s+0}')
  printf '%s' "${n:-0}"
}

check() {
  local out="$1" rc="$2" skipped invalid
  skipped=$(count skipped "$out")
  invalid=$(count invalid "$out")
  echo "integration: rc=$rc skipped=$skipped invalid=$invalid"
  if [ "$skipped" != "0" ]; then
    echo "::error::$skipped integration tests skipped -- the database environment is missing in CI"
    return 1
  fi
  if [ "$invalid" != "0" ]; then
    echo "::error::$invalid integration tests invalid -- a setup_all raised"
    return 1
  fi
  return "$rc"
}

case "$mode" in
  run)
    out=$(mktemp)
    mix test --include integration > "$out" 2>&1
    rc=$?
    cat "$out"
    check "$out" "$rc"
    rc=$?
    rm -f "$out"
    exit "$rc"
    ;;
  check)
    check "${2:?summary file}" "${3:?test exit code}"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
