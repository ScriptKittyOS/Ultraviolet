#!/usr/bin/env bash
#
# One implementation of every commit gate, called by BOTH .githooks/pre-commit and
# .github/workflows/ci.yml.
#
# Why this file exists: the hook and the workflow used to carry separate copies of the
# same logic, and the workflow's copy ran under GitHub's default `shell: bash -e`. Under
# -e a bare `mix test` that exits non-zero aborts the step before the comparison runs, so
# thirteen consecutive CI runs reported a failure without ever measuring one -- while the
# hook, which uses `set -uo pipefail` and no -e, passed the identical logic locally. The
# workflow's comment said "Must match .githooks/pre-commit"; it matched in logic and
# diverged in shell invocation, which is exactly the kind of difference a comment cannot
# hold. One script removes the class of defect, not just the instance.
#
# `set +e` on the next line is load-bearing. Derived, not argued: remove it, invoke
# `bash -e tools/gate.sh test` against a suite with real failures, and the gate exits 2
# printing NO verdict at all; with it, the same run prints `FAIL -- N failing test(s)`.
# That is the slice-13 defect class -- a gate reporting a result it never measured.
#
# WHICH construct aborts is deliberately NOT asserted here. Two different mechanisms were
# written into this comment and both were wrong; the fact above is the part that was
# measured. The mechanism is an open question in the slice 16b findings record. A comment
# asserting a mechanism nobody derived is the defect class that produced every blocking
# finding across C1 and C2.
set +e
set -uo pipefail

BASELINE="${BASELINE:-.claude/gate-baseline.json}"
LOGDIR="${LOGDIR:-$(mktemp -d)}"
# Create it. `mktemp -d` made the directory as a side effect, so setting LOGDIR to a path
# that does not exist yet -- which is exactly what pointing it at the CI workspace does --
# broke every redirect. Four gates went red on run 33586534853 for this reason. They failed
# CLOSED, refusing to report a pass they could not measure, which is the behaviour the
# class-1 rule requires; but a gate that cannot write its log is a broken gate, not a
# finding about the code under test.
mkdir -p "$LOGDIR" || { echo "gate: cannot create LOGDIR=$LOGDIR" >&2; exit 1; }

note() { printf '  %-24s %s\n' "$1" "$2"; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# THE definition of "a baseline value", and the only one. Takes (file, key).
#
# This is one function rather than two identical ones on purpose. It used to be duplicated,
# and the copies drifted: `baseline_of` read with `jq -r ".k // empty"`, which stringifies, so
# a JSON *string* "200" passed is_uint and became a baseline of 200, while baseline_gate's
# stricter reader saw the same key as ABSENT. A real credo regression (76 -> 200) passed both
# gates with no _corrections entry. Re-derivable: check out a commit with the lax reader
# (e8c9a94 is one), set credo_issues to the string "200", and run `baseline` and `credo`.
# An earlier version of this comment added "and licensed a retirement for it" -- that is NOT
# derivable from any committed state, because no commit with the lax reader has any _retired
# handling at all (`git show e8c9a94:tools/gate.sh | grep -c _retired` -> 0). It described a
# working state during review, which is not evidence a later reader can check.
#
# Two byte-identical copies would have been just as wrong: identical today is not the same as
# one definition, and nothing stops the next edit from touching one of them. The test for this
# is a mutation, not a grep -- change what this returns and BOTH readers must move together.
top_uint() {
  jq -r --arg k "$2" 'if (has($k) and (.[$k] | type == "number")) then .[$k] else empty end' \
    "$1" 2>/dev/null
}

baseline_of() {
  local k
  k=$(top_uint "$BASELINE" "$1") || return 1
  is_uint "$k" || return 1
  printf '%s' "$k"
}

# ExUnit exits 0 (all passed) or 2 (tests failed). Anything else -- a CompileError in a
# later app's test/, a timeout, OOM, SIGINT -- means the run did not measure every app,
# and a partial log summing to fewer failures would otherwise read as an improvement.
count_test_failures() {
  case "${TEST_STATUS:-1}" in 0|2) ;; *) return 1 ;; esac
  local want got
  want=$(ls -d apps/*/test 2>/dev/null | wc -l)
  got=$(grep -cE '[0-9]+ tests?, [0-9]+ failures?' "$1")
  # A gate that measures nothing is not a pass. `got >= want` alone degenerates when there is
  # nothing to measure: with no apps/*/test directories, want=0 and got=0, `0 >= 0` holds, and
  # an EMPTY log with TEST_STATUS=0 scored `pass (0 failures)`. That was survivable while this
  # was a ratchet against a baseline of 0; it is not survivable now that it is the hard
  # barrier. Same rule baseline_gate already applies with "compared 0 keys".
  [ "$want" -ge 1 ] || return 1
  [ "$got"  -ge 1 ] || return 1
  [ "$got" -ge "$want" ] || return 1
  # `invalid` is counted: a raising setup_all reports "N tests, 0 failures, N invalid",
  # which must not read as an improvement. `excluded` is deliberately NOT counted -- the
  # 18 integration-tagged tests are excluded by design in this job. The consequence is
  # recorded honestly: adding @tag :skip shrinks the measured surface without moving the
  # ratchet, which is why the test-identity manifest is still open work.
  local fails invalid
  # The summing tool is not the point; `${fails:-0}` was. With `paste | bc` and bc absent the
  # sum came back EMPTY and that default turned it into a clean 0, so a log with twelve real
  # failures scored as a pass. Measured, not assumed: bc IS present on the GitHub runner
  # today (a CI run reported `credo held at 76`, which count_credo could not have produced
  # without it), so this was a latent fail-open rather than an active one -- but it sat under
  # the gate that is now the hard barrier, and it depended on a tool staying installed.
  #
  # awk replaces bc because it is in every base image, and the DEFAULT IS GONE: a
  # non-numeric sum now fails closed. Swapping one unguarded tool for another would have
  # relocated the hole, not closed it -- awk missing produced the identical false pass.
  fails=$(grep -oE '[0-9]+ failures?' "$1" | grep -oE '^[0-9]+' | awk '{s+=$1} END {print s+0}')
  invalid=$(grep -oE '[0-9]+ invalid' "$1" | grep -oE '^[0-9]+' | awk '{s+=$1} END {print s+0}')
  is_uint "$fails" && is_uint "$invalid" || return 1
  printf '%s' "$(( fails + invalid ))"
}

# A clean run prints "found no issues" and no category totals -- that is 0, not a
# measurement failure. Without this the gate becomes unsatisfiable the day it passes.
count_credo() {
  grep -qE '^[0-9]+ mods/funs, found no issues' "$1" && { printf 0; return 0; }
  grep -qE '[0-9]+ (warning|refactoring opportunit|code readability issue|software design suggestion|consistency issue)' "$1" || return 1
  # awk for the same reason as count_test_failures: bc may be absent, and an empty result
  # here reaches `ratchet` as a non-numeric value. That one fails closed rather than open --
  # `is_uint` rejects it -- but relying on a downstream guard for an avoidable empty string
  # is the difference between failing closed by design and by luck.
  grep -oE '[0-9]+ (warnings?|refactoring opportunit(y|ies)|code readability issues?|software design suggestions?|consistency issues?)' "$1" \
    | grep -oE '^[0-9]+' | awk '{s+=$1} END {print s+0}'
}

count_dialyzer() {
  grep -qE '^done \(passed successfully\)' "$1" && { printf 0; return 0; }
  grep -oE 'Total errors: [0-9]+' "$1" | grep -oE '[0-9]+$' | head -1
}

# A gate whose baseline reached zero and was retired. Same measurement function as the
# ratchet used, same fail-closed contract -- an unparseable log, a partial run, or a
# non-numeric result is a failure, never a pass -- but the only passing value is 0.
#
# Deliberately NOT implemented as `ratchet` against a hardcoded 0: the ratchet's contract
# includes "improved to N -- lower the baseline", which is meaningless once there is no
# baseline to lower.
hard_zero() {
  local label="$1" fn="$2" log="$3" now
  now=$("$fn" "$log") || { note "$label" "FAIL -- gate produced no parseable result (see $log)"; return 1; }
  is_uint "$now"      || { note "$label" "FAIL -- non-numeric result '$now'; refusing to treat as a pass"; return 1; }
  if [ "$now" -eq 0 ]; then note "$label" "pass (0 failures)"; return 0; fi
  note "$label" "FAIL -- $now failing test(s); this gate is hard-blocking, there is no baseline"
  return 1
}

ratchet() {
  local label="$1" key="$2" fn="$3" log="$4" base now
  base=$(baseline_of "$key") || { note "$label" "FAIL -- no single integer \"$key\" in $BASELINE"; return 1; }
  now=$("$fn" "$log")        || { note "$label" "FAIL -- gate produced no parseable result (see $log)"; return 1; }
  is_uint "$now"             || { note "$label" "FAIL -- non-numeric result '$now'; refusing to treat as a pass"; return 1; }
  if   [ "$now" -gt "$base" ]; then note "$label" "REGRESSION: $now > baseline $base"; return 1
  elif [ "$now" -lt "$base" ]; then note "$label" "improved to $now (baseline $base) -- lower the baseline to $now"; return 1
  else                              note "$label" "held at $now"; return 0
  fi
}


# ---------------------------------------------------------------------------
# baseline: values may only DECREASE, unless a matching _corrections entry
# ships in the same reviewed diff.
#
# Takes the git ref holding the PREVIOUS baseline. The hook passes HEAD. CI passes
# github.event.before, NOT HEAD~1: GitHub creates one run per push, at the tip, so
# comparing HEAD~1 checks only the last commit. Pushing commit A (which raises a
# baseline) followed by commit B compares B against A, prints "90 -> 90", and exits 0 --
# A's raise is never compared, and no later run revisits it. On a slice branch a
# multi-commit push is the normal case, so that hole is the common path, not the corner.
#
# Fails closed on zero comparisons, with EXACTLY ONE exception: the all-zeros sentinel
# branch below, which returns 0 having compared nothing. That carve-out is stated here, in the same
# sentence as the rule, and not two paragraphs below it -- because the line this replaces
# said "Fails closed on zero comparisons" as an unqualified universal and was read that way
# for as long as it stood, while the empty-ref path passed on zero comparisons. Slice 16k
# closed that path; review then caught the replacement making the same structural mistake in
# weaker form. It is not the first correction of this kind in this function -- see the
# "too strong and is corrected here" note further down, and the two-wrong-mechanisms note
# near the top of the file. (An ordinal stood here and was dropped: nobody can check "the
# third", and the count moves every time another one is written.)
# A headline universal whose exception lives further down is how the first one survived.
#
# What changed in 16k: an empty string matched the same branch as the sentinel and returned
# 0. `github.event.before` is absent from the schedule and workflow_dispatch payloads, so CI
# took that path on two of its four triggers; run 34028977996 (schedule, main, 778accb8) is
# green on zero comparisons, printing "no previous ref (new branch)" about a branch that is
# `main`.
#
# Empty is not a ref. It is never a value a caller means; it only arrives from a payload
# field that was not populated, and a gate handed one has measured nothing and must say so.
# The all-zeros SENTINEL is different -- a real value with a real meaning, a push that
# creates a branch -- and still returns 0 in that branch.
#
# No PRODUCTION caller reaches it: .githooks/pre-commit:247 passes a literal HEAD, and
# ci.yml's `elif` intercepts all-zeros and routes it to `sha~1`. One caller does --
# apps/hacktui_core/test/ci_baseline_guard_test.exs, which pins this branch by running it.
# (Two earlier versions of this paragraph were wrong and both were caught by review: the
# first called the pass "a local fallback" when no local caller existed, and the second said
# NO caller in the tree reaches it, in the same commit that added one.)
#
# It is kept because the sentinel is a real git value a future caller may legitimately hand
# over, and because deleting it would answer that caller with a message about the wrong
# thing. Measured, with the branch deleted in a throwaway copy:
#
#     baseline  FAIL -- .claude/gate-baseline.json absent at 0000...0000; refusing to pass unmeasured
#
#   (the forty zeros are abbreviated; nothing else is trimmed)
#
# -- a report that a file is missing at a ref, when the ref is a sentinel meaning "there is
# no previous ref". An earlier version of this sentence guessed the caller would land on the
# empty-ref refusal instead. It would not; the guess was measured and was wrong.
#
# Previously the PR path could exit 0 having compared nothing and printed nothing, because
# `git show` had no failure branch and an empty `old` made every key skip.
# ---------------------------------------------------------------------------
baseline_gate() {
  local ref="${1:-}" prev="$LOGDIR/base.prev" compared=0 raised=0

  [ -r "$BASELINE" ] || { note baseline "FAIL -- $BASELINE missing or unreadable"; return 1; }

  if [ -z "$ref" ]; then
    note baseline "FAIL -- empty ref; refusing to pass unmeasured (an absent event payload field, not a ref)"
    return 1
  fi

  if [ "$ref" = "0000000000000000000000000000000000000000" ]; then
    note baseline "all-zeros sentinel (branch created by this push); nothing to compare"
    return 0
  fi

  if ! git cat-file -e "$ref:$BASELINE" 2>/dev/null; then
    note baseline "FAIL -- $BASELINE absent at $ref; refusing to pass unmeasured"
    return 1
  fi

  git show "$ref:$BASELINE" > "$prev" 2>/dev/null || {
    note baseline "FAIL -- could not read $BASELINE at $ref"; return 1; }

  # jq, not grep, for everything below. A `grep '"credo_issues": [0-9]+'` matches the key
  # ANYWHERE in the file, so a nested occurrence -- inside _targets, _corrections, or a prose
  # "reason" -- reads as the top-level baseline. Four holes were demonstrated against the
  # grep implementation before it shipped: deleting a top-level key while leaving a nested
  # decoy made the gate print "credo_issues: 76 -> 76", a comparison it never performed
  # against a key that no longer existed; a bare top-level "retired_key" licensed a deletion
  # with no _retired array present at all; and the same string smuggled into an existing
  # _corrections object did too. jq scopes every read to the structure it means.
  command -v jq >/dev/null 2>&1 || {
    note baseline "FAIL -- jq not available; refusing to compare baselines unparsed"; return 1; }
  # `jq -e .` exits non-zero for `null` and `false`, which ARE valid JSON -- just falsy.
  # Both still fail closed, which is right; the message was wrong about why.
  jq -e 'type == "object"' "$BASELINE" >/dev/null 2>&1 || {
    note baseline "FAIL -- $BASELINE is not a JSON object"; return 1; }

  # Scoped to _retired and to an object member named retired_key. A stray
  # "retired_key" elsewhere in the file is not a declaration.
  declared_retired() {
    jq -e --arg k "$2" '[._retired[]? | select(.retired_key == $k)] | length > 0' \
      "$1" >/dev/null 2>&1
  }

  # ---------------------------------------------------------------------------
  # _retired integrity, checked ONCE over the whole array and over EVERY key it names --
  # not per known key inside the loop below.
  #
  # The subject is the _retired array ACROSS COMMITS, not any single key's current value.
  # Splitting it into per-key half-checks is what let two forgeries through: a `first(...)`
  # read returned the ORIGINAL entry so an appended second entry was never compared, and a
  # value guard that only fired when the key still existed at the previous ref covered only
  # the retirement instant -- the case that was already covered -- and skipped the steady
  # state where the corruption actually happens. Both were measured passing green.
  #
  # Note the key list: the loop below iterates three known baselines, so a _retired entry
  # naming any OTHER key (hex_audit_advisories, say) was never examined at all. Measured:
  # declared-retired-and-still-present passed green for an unguarded key while correctly
  # failing for a guarded one. These rules read the array, so they cover every key in it.
  # ---------------------------------------------------------------------------
  local prev_ret now_ret dup rk rat rprev
  prev_ret=$(jq -S -c '._retired // []' "$prev"     2>/dev/null) || prev_ret='[]'
  now_ret=$( jq -S -c '._retired // []' "$BASELINE" 2>/dev/null) || now_ret='[]'

  # RULE 0 -- SHAPE, checked before any rule that reads a field. Every rule below reads this
  # array, and a malformed entry must fail HERE with a message about shape rather than making
  # a later reader error out mid-flight.
  #
  # This is not hypothetical. jq streams: an entry whose retired_key was `{}` or `[]` made the
  # @tsv reader for rules 3/3a abort, and because it aborts it emitted NOTHING -- so with
  # 2>/dev/null an errored jq read as "no violations found" and rules 3 and 3a were skipped
  # for EVERY new entry in the diff. Measured: a forged retirement carrying no retired_at at
  # all passed rc=0 with such an entry placed first, where the byte-identical file without it
  # failed rc=1. Ordering was the attacker's to choose.
  #
  # Scoped deliberately: the STRUCTURAL requirement (array of objects, non-empty string
  # retired_key) applies to the whole array, because every rule below reads those fields. The
  # VALUE requirement on retired_at applies only to entries NEW in this diff, and is enforced
  # further down where new entries are already being walked.
  #
  # Requiring numeric retired_at across the whole array would be a trap with no exit: entries
  # are immutable in every field by Rule 1, and an earlier gate accepted the string form, so a
  # landed `"retired_at": "0"` would flip an UNCHANGED file to FAIL permanently, with no
  # sanctioned-correction path. Not reachable in this repo -- the one live entry is numeric and
  # a replay of every commit is clean -- but a rule that can strand a valid file is the wrong
  # rule. New entries are the forgery vector; old ones are held by immutability.
  #
  # retired_key must be NON-EMPTY: "" is a string, and @tsv emitting a leading empty field
  # collapses under IFS=$'\t', shifting the pair so the FAIL message names a value instead of
  # a key.
  if ! jq -e -n --argjson q "$now_ret" \
       '($q | type) == "array"
        and ($q | all(.[];
              (type == "object")
              and ((.retired_key | type) == "string")
              and ((.retired_key | length) > 0)))' \
       >/dev/null 2>&1; then
    note baseline "FAIL -- _retired must be an array of objects, each with a non-empty string retired_key"
    return 1
  fi

  # RULE 1 -- immutable and append-only. Every entry present at the previous ref must still
  # be present now. Equality is jq -S canonical NUMERIC equality over the ENTIRE entry object,
  # every field, not a selected subset: a changed `reason` or `slice` is caught as readily as a
  # changed `retired_at`, and key order or whitespace cannot disguise an edit.
  #
  # "numeric equality" is the precise word and the earlier "equality over every field" was
  # marginally stronger than the mechanism: jq treats 76 and 76.0 as ONE number, so editing an
  # existing entry's retired_at from 76 to 76.0 is accepted as unchanged (rc=0), while 76 -> 77
  # is caught (rc=1). Semantically a no-op, and stated rather than left for a reader to discover.
  if ! jq -e -n --argjson p "$prev_ret" --argjson q "$now_ret" \
       '(($p - $q) | length) == 0' >/dev/null 2>&1; then
    note baseline "FAIL -- a _retired entry present at $ref was removed or altered; the record is append-only and immutable"
    return 1
  fi

  # RULE 2 -- at most one entry per key. This is also what removes the "which entry counts?"
  # ambiguity that produced the first-entry read.
  dup=$(jq -r -n --argjson q "$now_ret" \
          '[$q[].retired_key] | group_by(.) | map(select(length > 1)) | map(.[0]) | first // empty' 2>/dev/null)
  if [ -n "$dup" ]; then
    note baseline "FAIL -- _retired has more than one entry for $dup; at most one per key"
    return 1
  fi

  # RULES 3 / 3a -- for every entry that is NEW in this diff: the key must have had a numeric
  # top-level value at the previous ref (3a: an absent value is a MISMATCH, never a skip --
  # the same class of gate-by-precondition that made the first attempt inert), and the
  # entry's retired_at must equal that value (3).
  #
  # The loop COUNTS what it consumed and compares against what jq should have produced. A
  # reader that aborts must never read as "nothing to check" -- the same assertion discipline
  # §4b already requires of scripted edits, applied to a gate's own reader.
  local want_rows got_rows
  want_rows=$(jq -r -n --argjson p "$prev_ret" --argjson q "$now_ret" '($q - $p) | length' 2>/dev/null)
  got_rows=0
  while IFS=$'\t' read -r rk rat; do
    got_rows=$((got_rows + 1))
    rprev=$(top_uint "$prev" "$rk")
    if ! is_uint "$rprev"; then
      note baseline "FAIL -- new _retired entry for $rk, which had no numeric baseline at $ref"
      return 1
    fi
    # The reader below emits "-" for a missing retired_at and "NaN" for one that is not a
    # non-negative integer, so the two failures are distinguishable and each message is true.
    # A previous version ran `tostring` over any JSON value: 76.0 came through as "76.0",
    # failed is_uint, and was reported as "carries no numeric retired_at" -- which was false,
    # since it IS a number. 7.6e1 meanwhile became "76" and passed. Same value, two verdicts.
    #
    # Not eliminated at the extremes, and said plainly rather than implied: this fails closed on
    # inputs no real count can produce; the message is wrong of the input. For 1e20 the reader
    # emits "1e+20" rather than "NaN", so the gate says "not a whole number" of a value that IS
    # a non-negative integer; -1 produces the same wording. Both are unreachable with real
    # baseline counts, and both refuse rather than pass, which is the property that matters.
    if [ "$rat" = "-" ]; then
      note baseline "FAIL -- new _retired entry for $rk carries no retired_at"
      return 1
    fi
    if ! is_uint "$rat"; then
      note baseline "FAIL -- new _retired entry for $rk has a retired_at that is not a whole number"
      return 1
    fi
    if [ "$rat" != "$rprev" ]; then
      note baseline "FAIL -- $rk's _retired entry records retired_at=$rat but its value at $ref is $rprev"
      return 1
    fi
  done < <(jq -r -n --argjson p "$prev_ret" --argjson q "$now_ret" \
             '($q - $p)[]
              | [ .retired_key,
                  ( if (has("retired_at") | not) then "-"
                    elif ((.retired_at | type) == "number")
                         and ((.retired_at | floor) == .retired_at)
                         and (.retired_at >= 0)
                    then (.retired_at | floor | tostring)
                    else "NaN" end ) ]
              | @tsv' 2>/dev/null)

  if ! is_uint "$want_rows" || [ "$got_rows" -ne "$want_rows" ]; then
    note baseline "FAIL -- read $got_rows of ${want_rows:-?} new _retired entries; refusing to pass on a partial read"
    return 1
  fi

  # RULE 3b -- a key may be declared retired, or carry a numeric baseline, but never both in
  # the same file. Otherwise a retirement declaration can be parked next to a live value.
  # Checked over every key named in _retired, which is what the per-key loop could not do.
  while IFS= read -r rk; do
    [ -n "$rk" ] || continue
    if is_uint "$(top_uint "$BASELINE" "$rk")"; then
      note baseline "FAIL -- $rk is declared retired in _retired and still present as a baseline"
      return 1
    fi
  done < <(jq -r -n --argjson q "$now_ret" '$q[].retired_key // empty' 2>/dev/null)

  local k o n
  for k in test_failures credo_issues dialyzer_warnings; do
    o=$(top_uint "$prev" "$k")
    n=$(top_uint "$BASELINE" "$k")

    # PRESENT BUT NOT A NUMBER. Neither a baseline nor a retirement. Treating it as absent is
    # exactly what let a stringified "200" read as a deletion while baseline_of still enforced
    # it as a number. Refuse to guess which one the author meant.
    if jq -e --arg k "$k" 'has($k)' "$BASELINE" >/dev/null 2>&1 && ! is_uint "$n"; then
      note baseline "FAIL -- $k is present in $BASELINE but is not a number"
      return 1
    fi

    # RETIREMENT RECORDS ARE APPEND-ONLY, and checking only the current file was not enough:
    # one commit could delete the _retired entry AND re-add the key, and the loop reported
    # nothing at all, because the key was absent at the previous ref and present now.
    if declared_retired "$prev" "$k"; then
      if ! declared_retired "$BASELINE" "$k"; then
        note baseline "FAIL -- $k's _retired entry was removed; retirement records are append-only"
        return 1
      fi
      if is_uint "$n"; then
        note baseline "FAIL -- $k is declared retired but present again in $BASELINE"
        return 1
      fi
      continue
    fi

    # RE-INTRODUCTION within a single diff: declared retired here and present here.
    if is_uint "$n" && declared_retired "$BASELINE" "$k"; then
      note baseline "FAIL -- $k is declared retired in _retired but present again in $BASELINE"
      return 1
    fi

    # RETIREMENT. A key present at the previous ref and absent now is how a clean gate
    # graduates to hard-blocking. It is also the one genuinely silent way to escape a
    # ratchet: delete the key AND change or remove its `ratchet` call in the same diff, which
    # is exactly this commit's own move. (Deleting the key alone is NOT silent -- the
    # corresponding gate then fails with `no single integer "<key>"`. The earlier claim that
    # it "reports nothing at all" was too strong and is corrected here.)
    #
    # So a disappearance must be declared, and the declaration must ship WITH the deletion:
    # otherwise one commit parks a licence and a later commit quietly spends it, with a
    # reviewable diff of a single deleted line.
    if is_uint "$o" && ! is_uint "$n"; then
      if ! declared_retired "$BASELINE" "$k"; then
        note baseline "FAIL -- $k present at $ref, absent now, with no _retired entry"
        return 1
      fi
      # retired_at is NOT re-checked here. Rules 0/3 above already validated it for every
      # entry new in this diff, over the whole _retired array rather than the three keys this
      # loop happens to iterate. Keeping a second copy here was worse than redundant: it used
      # `first(...)`, which reads the FIRST entry for a key and so could not see an appended
      # forgery, and it compared the raw JSON text, so an integral float like 43.0 failed
      # against a baseline of 43 while 7.6e1 passed. Two checks for one invariant, disagreeing.
      # Deliberately NOT counted toward `compared`: retiring every key would otherwise
      # satisfy the fail-closed "compared 0 keys" check while comparing nothing.
      note baseline "$k retired at $o with a recorded _retired entry (its gate must be hard; not checked here)"
      continue
    fi

    is_uint "$o" && is_uint "$n" || continue
    compared=$((compared + 1))
    if [ "$n" -gt "$o" ]; then
      # An increase is permitted ONLY with a matching, reviewable entry in _corrections.
      # An audit record, not a bypass: the reason ships in the reviewed diff. CI used to
      # reject every raise unconditionally while the hook honoured corrections, so a
      # sanctioned correction passed locally and reddened CI. One implementation now.
      #
      # Scoped to the _corrections array for the same reason as _retired: the previous
      # `grep -A6` matched any "key"/"from"/"to" trio within six lines, anywhere.
      if jq -e --arg k "$k" --argjson o "$o" --argjson n "$n" \
           '[._corrections[]? | select(.key == $k and .from == $o and .to == $n)] | length > 0' \
           "$BASELINE" >/dev/null 2>&1; then
        note baseline "$k raised $o -> $n with a recorded correction (see _corrections)"
        raised=$((raised + 1))
      else
        note baseline "FAIL -- $k raised $o -> $n with no _corrections entry"
        return 1
      fi
    else
      note baseline "$k: $o -> $n"
    fi
  done

  [ "$compared" -gt 0 ] || {
    note baseline "FAIL -- compared 0 keys; a gate that measures nothing is not a pass"
    return 1; }
  return 0
}


# ---------------------------------------------------------------------------
# attestation: the gate DERIVES the diff hash and compares it to the commit's claim.
#
# The old signoff gate read a number the author wrote into a file and checked that the
# same number was there. With nothing staged that number is the sha256 of the empty
# string, and the gate reported "matches staged diff" for a diff that did not exist.
#
# The structural problem is not the empty hash: it is that the attested party supplied the
# value the gate checked. Same shape as joint invariant J8 -- the party accountable for
# observing a plane must be a different privilege domain from the party accountable for its
# behaviour -- applied to this repo's own review record. So the author now supplies a
# CLAIM, in a commit trailer, and the gate independently derives the FACT and compares.
#
# Checked per commit, not per range: a push carries several commits and each must attest to
# its own diff, for the same reason the baseline gate compares github.event.before rather
# than HEAD~1.
#
# NOT in scope here: proving WHO produced the claim. That needs a signature verified
# against a tracked allowed-signers file. This slice removes the author's ability to hand
# the gate its own answer; it does not yet make the attester a different party.
# ---------------------------------------------------------------------------
# ONE definition of the reviewable-diff recipe. Every consumer reads these two arrays:
# attestation (derive_diff_hash), the pre-commit signoff check and tools/signoff.sh
# (staged_diff_hash, via the `staged-diff-hash` subcommand). This is the class-(a) rule
# applied to itself -- two byte-identical copies pass a grep count, so the only honest test
# is a mutation, and a mutation needs exactly one thing to mutate.
#
# .githooks/commit-msg still carries its own copy: it runs in a context where sourcing this
# script is a behaviour change, and removing that copy is slice 17's work. It does not sit
# on faith in the meantime -- apps/hacktui_core/test/diff_recipe_test.exs asserts the two
# token sequences are identical, so they cannot drift silently inside that window.
DIFF_RECIPE=(-c diff.noprefix=false -c diff.context=3 -c diff.algorithm=myers -c core.abbrev=40 -c diff.renames=true -c diff.renameLimit=0)
DIFF_SCOPE=(--binary --no-ext-diff --no-textconv -- . ':(exclude)internal/**')

derive_diff_hash() {
  git "${DIFF_RECIPE[@]}" diff "$1" "$2" "${DIFF_SCOPE[@]}" | sha256sum | cut -d' ' -f1
}

# The same recipe against the index. `git diff --cached` takes no ref pair, which is why it
# cannot simply call derive_diff_hash -- but it reads the same two arrays, so a change to the
# recipe moves both or neither.
#
# THREE things this has to get right, all of them found by review rather than by design:
#
#  1. It must FAIL when it cannot measure. The first version piped `git diff` straight into
#     sha256sum, so when git errored -- outside a repository, say -- sha256sum hashed empty
#     input and produced e3b0c442..., a perfectly well-formed 64-hex string, with rc=0. A
#     caller that cannot measure must not receive something that looks like a measurement;
#     that is the defect class this whole file was written to remove, committed inside the
#     commit that removes it. PIPESTATUS carries git's status out of the pipeline.
#  2. It must not depend on the caller's directory. DIFF_SCOPE ends in `-- .`, which is
#     relative, so the same index answered differently from the root and from a subdirectory
#     -- returning the empty-diff hash, with rc=0, while a change was staged. It resolves the
#     toplevel itself rather than trusting the caller to have cd'd.
#  3. It must not use $(...) on the diff BYTES. Command substitution strips trailing newlines,
#     so the hash would silently differ from every other consumer's. Measured: pipeline
#     9fed0f8d..., $(...) 0cad12fe..., and re-appending the one stripped newline restores
#     9fed0f8d... exactly. Only the finished hex string passes through a substitution.
#     (An earlier version of this comment also blamed NULs "that --binary hunks contain". That
#     is wrong and was corrected by review: --binary hunks are base85 ASCII -- `tr -dc '\000'`
#     over such a diff counts zero. Bash does drop NULs from a substitution, but the diff of a
#     binary file is not where they come from. The trailing newline alone is the reason.)
staged_diff_hash() {
  local top h rc
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  h=$(
    cd "$top" || exit 1
    git "${DIFF_RECIPE[@]}" diff --cached "${DIFF_SCOPE[@]}" | sha256sum | cut -d' ' -f1
    exit "${PIPESTATUS[0]}"
  )
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$h" | grep -qE '^[0-9a-f]{64}$' || return 1
  printf '%s' "$h"
}

attestation_gate() {
  local range="${1:-}" commits c parent derived claimed n=0 bad=0

  [ -n "$range" ] || { note attestation "FAIL -- no commit range given"; return 1; }

  commits=$(git rev-list --no-merges "$range" 2>/dev/null) || {
    note attestation "FAIL -- cannot enumerate $range"; return 1; }

  [ -n "$commits" ] && [ "$commits" != "" ] || {
    note attestation "no commits in $range; nothing to check"; return 0; }

  for c in $commits; do
    n=$((n + 1))
    parent=$(git rev-parse "$c^" 2>/dev/null) || parent=$(git hash-object -t tree /dev/null)
    derived=$(derive_diff_hash "$parent" "$c")

    # An empty diff can never be a match. This is the defect this slice closes: the sha256
    # of the empty string is a real hash, and a signoff containing it used to pass.
    if [ "$derived" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
      note attestation "NOTHING TO ATTEST -- ${c:0:8} has an empty reviewable diff"
      bad=1
      continue
    fi

    claimed=$(git log -1 --format=%B "$c" | sed -n 's/^Reviewed-diff:[[:space:]]*sha256:[[:space:]]*\([0-9a-f]\{64\}\).*/\1/p' | head -1)

    if [ -z "$claimed" ]; then
      note attestation "FAIL -- ${c:0:8} carries no Reviewed-diff trailer"
      bad=1
    elif [ "$claimed" != "$derived" ]; then
      note attestation "FAIL -- ${c:0:8} claim does not match its diff"
      printf '      claimed:  %s\n      derived:  %s\n' "$claimed" "$derived"
      bad=1
    else
      note attestation "${c:0:8} attests to its own diff (${derived:0:16}...)"
    fi
  done

  [ "$bad" -eq 0 ] || return 1
  return 0
}

case "${1:?usage: tools/gate.sh <format|compile|secret-scan|test|credo|dialyzer|mutation|baseline|attestation|advisories|staged-diff-hash>}" in

  format)
    mix format --check-formatted >/dev/null 2>&1 \
      && { note format "pass"; exit 0; } || { note format "FAIL -- run: mix format"; exit 1; }
    ;;

  compile)
    mix compile --warnings-as-errors >/dev/null 2>&1 \
      && { note compile "pass"; exit 0; } || { note compile "FAIL (--warnings-as-errors)"; exit 1; }
    ;;

  secret-scan)
    # Anchored deliberately: an unanchored 'env' matched .../envelope.ex on every run, so
    # the gate could never pass and would have been learned as noise.
    secrets=$(git ls-files | grep -Ei '(^|/)\.env$|\.(key|pem|pcap|pcapng|p12)$')
    [ -z "$secrets" ] && { note "tracked-secret-files" "pass"; exit 0; }
    note "tracked-secret-files" "FAIL -- tracked secret-shaped files:"; printf '%s\n' "$secrets" | sed 's/^/      /'; exit 1
    ;;

  test)
    # HARD gate since slice 16. The baseline reached 0 in slice 13 and its entry was retired,
    # as .claude/gate-baseline.json's own _comment requires. The CI job keeps the name
    # "Gate - test ratchet" because that string is a required status check in the branch
    # ruleset and renaming it would leave a required context that never reports, blocking
    # every PR (CLAUDE.md 4c). The rename is owner work, tracked in BACKLOG.md.
    mix test > "$LOGDIR/test.log" 2>&1; export TEST_STATUS=$?
    hard_zero "test (hard)" count_test_failures "$LOGDIR/test.log"
    ;;

  credo)
    MIX_ENV=dev mix credo --strict > "$LOGDIR/credo.log" 2>&1
    ratchet "credo (ratchet)" credo_issues count_credo "$LOGDIR/credo.log"
    ;;

  dialyzer)
    MIX_ENV=dev mix dialyzer --format raw > "$LOGDIR/dz.log" 2>&1
    ratchet "dialyzer (ratchet)" dialyzer_warnings count_dialyzer "$LOGDIR/dz.log"
    ;;

  baseline)
    baseline_gate "${2:-}"
    ;;

  attestation)
    attestation_gate "${2:-}"
    ;;

  mutation)
    ./tools/mutate.sh tools/mutants/c5.tsv
    ;;

  advisories)
    # Advisory only: recorded, never blocking. Promotion to a ratchet is slice 18.
    mix do deps.loadpaths + deps.audit 2>&1 | tail -3
    mix hex.audit 2>&1 | tail -3
    note advisories "recorded (not blocking until slice 18)"
    ;;

  # Not a gate: it prints the one canonical staged-diff hash so .githooks/pre-commit and
  # tools/signoff.sh do not need a copy of the recipe. It emits a hash and nothing else, and
  # exits non-zero in every case where it did not measure one.
  #
  # The empty-diff hash is refused here rather than left to each caller. It IS well formed, so
  # a format check cannot catch it; .githooks/commit-msg and tools/signoff.sh each carry their
  # own sentinel test and .githooks/pre-commit did not, which is exactly the asymmetry that
  # makes a per-caller check the wrong place for it.
  staged-diff-hash)
    [ "$#" -eq 1 ] || {
      echo "staged-diff-hash: takes no arguments (got: ${*:2})" >&2; exit 2; }
    h=$(staged_diff_hash) || {
      echo "staged-diff-hash: could not measure the index; refusing to print a hash" >&2; exit 2; }
    [ "$h" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ] && {
      echo "staged-diff-hash: the staged reviewable diff is empty; nothing to hash" >&2; exit 2; }
    printf '%s\n' "$h"
    ;;

  *) echo "unknown gate: $1" >&2; exit 2 ;;
esac
