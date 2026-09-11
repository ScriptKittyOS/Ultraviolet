#!/usr/bin/env bash
# Probe harness for mutation and drift probes. Sits beside tools/mutate.sh for the same reason:
# a harness that is not in the repository cannot be checked by a third party, so its claim to
# have "written this at execution" rests on the author's word.
#
# The tree hash is printed on the same line as the result, derived inside the probe worktree
# immediately before the mutation and again immediately after. A probe run at the wrong tree
# is visible in one line.
#
# The harness does NOT restore. Restoration is the caller's job, and the harness verifies it
# instead: each run prints the tree it started from, so a caller whose restore is incomplete
# shows a drifting tree= column on the very next line.
#
# Probes run against a copy, never the canonical repository; see the harness refusal control
# in apps/hacktui_core/test/schemas_digest_test.exs.
#
# Usage:  tools/probe.sh <worktree> <log> <name> <edit-command> [<test-target>]
set -uo pipefail

wt="${1:?worktree}"; log="${2:?log}"
name="${3:?probe name}"; edit="${4:?edit command}"; target="${5:-}"

# Refuse the canonical repository, not merely "the repo the caller happens to stand in".
# The canonical path is resolved from the target itself and compared against the common git
# dir, so a real worktree of the real repo is refused however the caller was invoked.
target_root="$(cd "$wt" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "REFUSING: $wt is not a git worktree." >&2; exit 2; }
target_common="$(cd "$wt" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
canonical_root="$(dirname "$target_common")"

[ "$target_root" != "$canonical_root" ] || {
  echo "REFUSING: $wt is the canonical repository. Probes run against a copy." >&2
  exit 2; }

cd "$wt" || exit 2
git add -A >/dev/null 2>&1; tree_before="$(git write-tree)"

if ! eval "$edit" >/dev/null 2>&1; then
  printf 'tree=%s  probe=%s  EDIT-ASSERT-FAILED\n' "$tree_before" "$name" | tee -a "$log"
  exit 1
fi

git add -A >/dev/null 2>&1; tree_mutated="$(git write-tree)"
out="$(mix test $target 2>&1)"; rc=$?
result="$(printf '%s' "$out" | grep -oE '[0-9]+ tests, [0-9]+ failures?')"

printf 'tree=%s  mutated_tree=%s  probe=%s  result=[%s]  exit=%s\n' \
  "$tree_before" "$tree_mutated" "$name" "$result" "$rc" | tee -a "$log"

exit 0
