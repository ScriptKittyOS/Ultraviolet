# Backlog

Open work that has no slice yet, and known gaps that a reader of this repository should be
able to find without asking anyone.

This file is **tracked on purpose**. Planning records live in `internal/slices/`, which is
gitignored, so they do not survive a clone — a lesson learned the expensive way. Anything
that must travel with the code belongs here, in `docs/`, or in `CLAUDE.md`; not in a slice
directory.

Related, and deliberately separate:

- `docs/residuals.md` — findings that were investigated and **deliberately not closed**, with
  the evidence that made them acceptable. A residual is a decision. A backlog item is work.
- `docs/not_production_ready.md` — what this system does not claim to be.

Nothing sensitive goes in this file: no credentials, no host identifiers, no captured
telemetry, no contents of unpublished planning documents.

---

## 1. Vulnerability advisories are recorded but not enforced — **slice 18**

`mix deps.audit` and `mix hex.audit` run in the commit hook and in CI, and their counts are
recorded in `.claude/gate-baseline.json` (12 and 20 at the time of writing). **Nothing fails
a build on them.** A newly introduced vulnerable dependency is therefore *reported* and not
*blocked*. `CLAUDE.md` §4 counts four gates that do not pass: `credo` and `dialyzer` are
ratcheted, and these two are the other pair — the ones with no enforcement at all.

This is a known, recorded deviation rather than an oversight, but it is the largest one.
Slice 18 promotes them to ratchets on the same footing as `credo` and `dialyzer`: a baseline
that may only decrease, with `_corrections` as the audit record for any sanctioned raise.

Until then, treat a clean CI run as saying nothing about dependency vulnerabilities.

**These two keys are also outside the baseline gate's guard.** `baseline_gate` in
`tools/gate.sh` iterates a fixed list — `test_failures`, `credo_issues`, `dialyzer_warnings` —
so `hex_audit_advisories` and `deps_audit_advisories` can be raised or deleted with nothing
comparing them. Measured, not assumed: a retirement declaration for `hex_audit_advisories`
passed green where the identical shape for `credo_issues` failed. The `_retired` integrity
rules added in slice 16b do cover every key named in `_retired`, so the *declaration* path is
guarded now; the *value* path is not, and will not be until these two become real ratchets.
Whoever picks this up should extend the key list in the same change.

Two in-tree comments in `tools/gate.sh` used to assign this work to slice 16, which is the
release and does not include it. This item recorded that disagreement, and the next commit to
touch that file corrected the comments to slice 18, so the code and the backlog now agree.
Re-derive with `grep -n "slice 18" tools/gate.sh` rather than trusting a line number here —
the surrounding code moves.

## 2. The integration job is advisory, and most of its failures are the job's fault

CI runs an `integration` job that is **advisory** — `continue-on-error: true`, so it does not
block. On run `33594696902` (the push run for `5a6e566`) it reported **four** failures:
`HacktuiStoreTest`, `HacktuiHub.SafeModeSmokeTest`, `HacktuiHub.ReplayIngestTest`, and
`HacktuiAgent.InvestigationFlowDbIntegrationTest`.

**Re-derive that count from the job log rather than quoting it here.** It has varied run to
run, and a fixed number in a document is exactly the kind of claim that goes stale silently.

There is **no single root cause.** Successive versions of this item each claimed one, and each
was wrong, so the dead explanation is recorded here to stop it being reintroduced:

> **Not the cause:** "the job sets `HACKTUI_START_REPO=true`, so repo-disabled tests fail."
> That variable is never read in the test environment — `config/runtime.exs:15` is
> `if config_env() != :test do`, `config/config.exs:33` sets `start_repo: false`, and
> `config/test.exs` does not override it. The workflow does set the variable, and it has no
> effect on the suite.

What `--include integration` actually does is **add** to the selection rather than narrow it,
so integration-tagged tests run in the same BEAM as everything else and mutate global state
the untagged tests depend on. **That is the enabling condition, and it is as far as the
established explanation goes.** The failures below are order-dependent, and every attempt to
state a per-test causal chain has been wrong in some detail. What follows is therefore
what was *measured*, with the mechanism marked established or not. Re-derive before acting;
do not treat any of it as settled because it is written down.

1. `HacktuiStoreTest` — `refute Process.whereis(HacktuiStore.Repo)` found a live repo, even
   though the test starts `:hacktui_store` itself first. Untagged. What is established:
   `:start_repo` is already `true` by then, because integration setup sets it and does not
   restore it — `stop_repo!/0` only calls `Application.stop/1`. Enumerate the setters with
   `grep -rn "put_env(:hacktui_store, :start_repo, true)" apps/*/test/`; that returns every
   site that mutates the value, of which the ones that clean up save a `previous` value first
   and the rest do not. Derive the split rather than quoting one — the count has gone stale
   once already. **Which** site is responsible for this failure depends on run order and is
   **not** established.
2. `HacktuiHub.SafeModeSmokeTest` — `assert hub.supervisor_started?` was false. Untagged, and
   **not a repo assertion**: `apps/hacktui_hub/lib/hacktui_hub/health.ex:9` defines that as
   `Process.whereis(HacktuiHub.Supervisor) != nil`. Had repo state been the cause, the failing
   assertion would have been `store.mode == :safe_no_repo` on the next line. What is
   established: integration tests stop `:hacktui_hub` in `on_exit`, several untagged modules
   restart it with `ensure_all_started/1`, and this test is unusual in asserting hub state
   **without** starting the application first — unlike `HacktuiStoreTest`, which does. Whether
   the hub happens to be up when it runs is therefore **seed-dependent**, and no single call
   site is the cause.
3. `HacktuiHub.ReplayIngestTest` — `audit_id: "has already been taken"`, a unique-constraint
   violation on `audit_events_audit_id_index`. **Not the same cause at all.** This test asserts
   nothing about repo state; the case-1 replay fixture is not idempotent once a real repo is
   present, so the second insert of a fixed `audit_id` collides. Tagging fixes nothing here.
   Either the fixture or the runner needs to tolerate re-running.
4. `HacktuiAgent.InvestigationFlowDbIntegrationTest` — a timeline-entry match failure. This one
   **is** tagged (`@moduletag :integration`, line 6), so the tagging work cannot explain or
   clear it either. Needs its own diagnosis.

Three decisions were pre-made, and they only address (1) and (2):

1. Tag what is genuinely `:integration`, so the tag selects rather than merely adds.
2. Run safe-mode tests in their own environment instead of inheriting the DB-backed one, and
   restore application state in `on_exit` at **every** site that mutates it — every
   `:start_repo` setter the grep above returns, not the subset cited anywhere. A safe-mode test
   should also establish the state it asserts rather than inheriting whatever the previous
   module left behind.
3. For `HacktuiSensor.Forwarder`, prefer **not** starting it under the application in the test
   environment, so tests start it under their own supervision. (This is sensor test hygiene,
   not one of the four failures — `hacktui_sensor` reported 0 failures on that run.)

**Unassigned.** `.github/workflows/ci.yml:205-206` says removing `continue-on-error` is
slice 16's work; slice 16 is the release and does not include it, so that comment is stale and
this item has no slice yet. Whoever picks it up should fix the comment in the same change.

## 3. Parked contracts schema

A hold-schema JSON file is parked under `internal/incoming/`, awaiting the contracts slice.
It is not in the published tree, and it is not part of any current interface. Recorded here so
its existence is discoverable from the repository rather than only from a local file.

It lives there because an untracked top-level `schemas/` directory blocked the commit gate
repeatedly: the gate refuses to measure a working tree that differs from the index.

## 4. No release-native MCP entry point

`bin/hacktui-mcp` runs `mix compile` and then `mix run --no-compile -e '...'`. Mix is not part
of an Elixir release, so the MCP server is reachable from a source checkout but **not** from a
built release.

The v0.1.0 release qualifies the MCP stdio path **from a clean clone**, which is what the
README documents. A release-native entry point is out of scope for that release and open work
here; when the release lands it is recorded in `docs/residuals.md` with the measurement that
justified accepting it. Anyone planning to embed HackTUI's MCP server in a deployed release
should know this before designing around it.

## 5. `fixup!` and `squash!` are text exemptions in `commit-msg`

`.githooks/commit-msg` exempts merge, revert and cherry-pick commits based on git's actual
state — `MERGE_HEAD`, `REVERT_HEAD`, `CHERRY_PICK_HEAD` — so a hand-typed "Merge branch x" is
still rejected.

`fixup!` and `squash!` remain **text** exemptions: typing that prefix skips the slice-reference
check. They are meant to be squashed away before landing, and the repository's merge method is
rebase, so they should never reach `main` — but the exemption is a hole in a gate that is
otherwise state-based, and it is recorded rather than assumed harmless.

It is not a route past review, and the reason matters: the exemption returns from the hook
**before** the attestation trailer is written, so such a commit carries no `Reviewed-diff`
trailer and is hard-failed by `tools/gate.sh attestation` ("carries no `Reviewed-diff`
trailer"). The gap is a missing slice reference on a commit that cannot pass CI, not a way to
land unattested work.

## 6. The `Gate - test ratchet` job name has outlived the ratchet

The test gate is **hard-blocking**: its baseline reached 0 in slice 13, and slice 16 retired
the entry from `.claude/gate-baseline.json` — what that file's own comment says to do with a
clean gate. Only 0 passes now; there is no baseline left to raise.

The CI job **keeps the name `Gate - test ratchet`**, and that is the item recorded
here: the string is a **required status check** in the branch ruleset, and a required context
that never reports leaves every pull request pending forever. Renaming it means editing the
ruleset and the workflow together, in that order, and only the repository owner can edit the
ruleset. See `CLAUDE.md` §4c.

## 7. Two of three sensor collectors cannot be enabled by following the documentation

`HacktuiSensor` starts three collectors. `Collectors.Journald` and `Collectors.Network` are
opt-in through `HACKTUI_SENSOR_JOURNALD` and `HACKTUI_SENSOR_NETWORK`, both defaulting to
off — and **neither variable appears in any user-facing documentation**: nothing under
`docs/`, not `README.md`, not `.env.example`. (They appear in this file and in `HANDOFF.md`,
which are process records, not runbooks.) A reader following the documentation cannot turn on
journald ingestion or network capture. `README.md` lists both under "HackTUI **currently
supports**", so the bullets are accurate about the code and unreachable in practice — which is
the worse of the two failure modes, because the reader concludes the feature is missing. `Collectors.ProcessSignals` has no
gate at all and starts unconditionally.

Slice 16 closes this: a third variable, `HACKTUI_SENSOR_PROCESS_SIGNALS`, defaulting to **on**
so that behaviour is unchanged for anyone already running the system; all three documented in
`.env.example` and `docs/runtime_modes_matrix.md`; and a test asserting both that each
variable starts exactly its own collector and that a documentation row exists for each, so the
two cannot drift apart again without `mix test` noticing.

**`HACKTUI_SENSOR_PROCESS_SIGNALS` does not exist yet** — it appears in this file and in the
slice plan and nowhere in the code. Setting it today does nothing; process signals collect
unconditionally until that change lands.

The default asymmetry is deliberate and worth keeping a reason for: process signals are a
local BEAM heartbeat, while journald reads the host journal and network capture is a
privileged host-wide side effect.

## 8. Branch protection does not require a human approver

The `main` ruleset requires a pull request, linear history, rebase merges and nine passing
gate checks, with no bypass actors. It does **not** require an approving review:
`required_approving_review_count` is `0` and `required_reviewers` is empty.

`CLAUDE.md` §0 — nothing is truth until independently reviewed — is therefore enforced by
process, not by the platform. Raising that count and naming reviewers is owner work.

The ruleset also targets **branches, not tags**. Tag pushes are unprotected: nothing prevents
a tag being created, moved, or deleted. That matters for release tags, which are the one
artefact people verify signatures against.

## 9. `sobelow` is advisory in the hook and absent from CI

`CLAUDE.md` §4 lists `mix sobelow --exit` among the gates a commit must pass. In practice it
is neither blocking nor present in CI:

- `.githooks/pre-commit` runs it per app with `|| true` and records a count as a note. It
  cannot fail a commit.
- `.github/workflows/` contains no `sobelow` step at all, so nothing runs it on a pull
  request.

It is the **third** advisory gate alongside the two dependency audits, and the only §4 gate
with no CI presence whatsoever.

**It currently reports 7 findings**, measured by the commit hook on the slice 16 baseline-
retirement commit. That number is recorded now so it cannot grow quietly while the gate is
unenforced: **when slice 18 picks this up, 7 is the initial ratchet baseline**, not a starting
point to be re-measured later against whatever the number has drifted to. Re-derive it with
`for a in apps/*/; do mix sobelow --root "$a" --exit; done` and count `^File:` lines.

Making it a **required** check is a ruleset edit, so the PLAN for that slice must carry the
copy-paste for the change and name the before/after context, per `CLAUDE.md` §4c.

The tool's own caveat still applies — there is no Phoenix application in this umbrella, so
much of what it checks does not exist here — which is an argument for scoping or dropping it
deliberately, not for leaving it looking enforced.

## 10. `PrivacyMask` recognises only RFC1918 and loopback IPv4

`HacktuiAgent.MCP.Egress` masks identity-bearing fields on every MCP read tool result, and its
own module documentation records the limit: `HacktuiHub.PrivacyMask` recognises only RFC1918
addresses and loopback, so hostnames, DNS names, TLS SNI values and URIs are masked by
**field name** only, and free text in `raw_message` is not redacted at all.

(The moduledoc says "loopback IPv4"; the implementation at
`apps/hacktui_hub/lib/hacktui_hub/privacy_mask.ex:40` also matches the IPv6 loopback `::1`, so
coverage is marginally wider than the comment claims. Worth correcting in the same change that
broadens it.)

That module points here for the broadening work, so the item is recorded here to give the
reference something real to land on. Nothing above is new disclosure: it is stated in the
tracked source at `apps/hacktui_agent/lib/hacktui_agent/mcp/egress.ex`, and the matching
predicate is published in full in `privacy_mask.ex`.

**This item is scoped to recognition breadth only.** It is not a complete account of the
control's limits: the funnel carries others that are **visible in the implementation but not
described in the moduledoc**, so reading the moduledoc alone returns this item and gives a
false sense of completeness. Anyone assessing what leaves the MCP boundary should read the
bodies of `egress.ex` and `privacy_mask.ex`, not this entry and not the doc comments.

## 11. `is_uint` is defined twice — advisory print only

`.githooks/pre-commit` carries a **byte-identical copy** of the `is_uint` helper defined in
`tools/gate.sh`. Found by a reviewer in slice 16b while checking that slice's own
one-invariant-one-implementation criterion.

**It governs an advisory print only.** `is_uint` has exactly one call site in the hook, inside
the `ADVISORY` block, and neither branch of it sets `fail` — so the commit verdict is
unreachable from the duplicated function. It decides whether a dependency-audit count is
printable, nothing more. **No baseline or ratchet logic is duplicated** — that is the point of
recording it here rather than filing it as a defect.

*(An earlier draft of this sentence said the hook "delegates every gate verdict to
`tools/gate.sh`". That was false of the tree and was falsified by the very commit that wrote
it: the hook renders several verdicts of its own — the branch refusal, the deleted-path check
and the `Reviewed-tree` check — and `CLAUDE.md` §4 lists all three as gates. The narrow claim
above is the one that was measured.)*

It is still the exact hazard the surrounding code names: **two byte-identical copies pass a
grep count.** Today they agree; nothing makes them agree tomorrow. A count is not proof of one
implementation — the only proof is a mutation, and a mutation needs one thing to mutate.

**Assigned to slice 17**, which removes the copy and imports the single definition; the hook
sourcing the function from `tools/gate.sh` is the obvious shape, and 17's PLAN decides it.

Deliberately cited by **construct, not line number**: both files change under active work, and
a line citation in a file under change is the stale-citation class this repository has already
committed once inside the document recording the fix for it.

## 12. The MCP surface changed in 16j

The MCP surface changed in slice 16j. Changes are pinned by tests in
`apps/hacktui_agent/test/mcp_stdio_framing_test.exs`.

`ping` carrying a `_meta` revision is a known `beam_mcp` defect, tracked as SCR-257, and is
pinned by no test here because a test would pin the defect.

## 13. The baseline gate still goes red on a force-pushed ref — SCR-69, second half

Slice 16k closed one half of SCR-69: `Gate - baseline may only decrease` used to go **green
having compared nothing** whenever the event payload carried no `before`, which is every
`schedule` and every `workflow_dispatch` run. Measured on runs `34028977996` and
`34071415451`, both green on zero comparisons. `.github/workflows/ci.yml` now carries the
same guard the attestation job has, and `baseline_gate` refuses an empty ref outright.

**The other half is open.** A force-push sets `github.event.before` to a well-formed SHA that
is reachable from no ref. That is not the all-zeros sentinel, so it reaches
`tools/gate.sh`'s `git cat-file -e "$ref:$BASELINE"`, which fails, and the gate goes **red on
a tree that is fine**.

Measured: run `33709449011` (`push`, head `27de8a1b`) failed with
`FAIL -- .claude/gate-baseline.json absent at d025d350…`. The tree was fine, and the run that
proves it is **`33709453098`** — the `pull_request` run on the *same head*, created four
seconds later (`02:55:25Z` and `02:55:29Z` per `gh api .../actions/runs/<id> --jq .created_at`),
which took the `base_ref` branch and compared both keys for real:

```
$ gh api repos/ScriptKittyOS/Ultraviolet/actions/jobs/100505623057/logs \
    | sed 's/\x1b\[[0-9;]*m//g'
[...]   ./tools/gate.sh baseline "origin/main"
[...]   baseline                 credo_issues: 76 -> 76
[...]   baseline                 dialyzer_warnings: 43 -> 43
```

`[...]` marks an elided ISO-8601 timestamp on each line, and the `sed` strips the ANSI colour
codes the API returns. The first line quoted is part of the runner's echo of the `run:` script,
not a trace; the untaken branch echoed beside it, and its invocation, are not reproduced.

No branch tally appears here. Consecutive review rounds each corrected the tally in this
sentence and each correction was wrong again — once by counting the current file against a log
from the older one. Read the log for what that run's script was, and
`sed -n '/^  baseline:/,/^  advisories:/p' .github/workflows/ci.yml | grep -cE '^\s*(if|elif|else)\b'`
for what it is now — scoped to the job, because unscoped over the whole file it counts every
job's branches. Nothing else was
added to the block -- an earlier draft carried an editorial comment inside it, which is the
same defect as an unmarked elision in the other direction. Marked rather than silently trimmed: a block under a
bare `$` prompt claims to be what the command prints.

**Not** run `33877201424`, which an earlier draft of this entry cited as the green control.
Review measured that its `before` was the all-zeros sentinel, so it compared **zero keys** —
it is a second sighting of the bug 16k closed, not evidence about the tree. It would also no
longer reproduce: `ci.yml`'s new `elif` now routes all-zeros to `${{ github.sha }}~1`, so that
same push performs a real comparison. Recorded because citing it would have sent whoever picks
this up chasing a green that the current code cannot produce.

`fetch-depth: 0` does not help; a full-depth fetch fetches refs, and an orphaned commit is
reachable from none.

This is the opposite failure direction from the one 16k fixed, and it wants a different
remedy: a reachability probe before the ref is used, and a decision about what to compare
against when the recorded start point no longer exists. Deliberately left out of 16k rather
than folded in.

## 14. Documentation drift — a class, to be derived and swept as one unit

Tracked documentation carries statements that were true when written and are not true now.
This is recorded as a **class with a derivation**, not as a list of instances: a list gets
fixed and the class stays open. Each entry names the **derivation** that finds the whole
population, so the sweep can prove it is complete rather than assert it. Only the first is a
runnable one-liner; the rest are procedures, and saying so is the difference between a
derivation and a command that does not exist. Review measured this distinction: the headline
here first claimed every entry "names the command", and most do not.

| class | derivation | known instances |
|---|---|---|
| a `mix` task cited in a tracked `.md` that does not exist | every `mix <task>` in `git grep -ho 'mix [a-z][a-z0-9_]*\(\.[a-z][a-z0-9_]*\)*' -- '*.md'`, checked against `mix help` | `mix phx.server` at `docs/operator_boot_runbook.md:9` — there is no Phoenix application in this umbrella |
| an umbrella app named in a doc that is not in `apps/` | every `hacktui[_a-z]*` cited as an app, checked against `ls apps/` | `ARCHITECTURE.md`'s "Umbrella apps" list has one more entry than `apps/` has directories — `sed -n '/^## Umbrella apps/,/^## Current/p' ARCHITECTURE.md \| grep -c '^- '` against `ls apps/ \| wc -l`, both run and checked, not written from memory. The extra one is `hacktui` itself, which is the umbrella **root** (`mix.exs`, `apps_path: "apps"`), not an app — so the sweep must decide whether to drop it or relabel it, and this cell deliberately does not pre-judge that. One reviewer read it as a real instance and one as a false positive; the disagreement is the finding |
| a doc quoting a command whose real output contradicts the doc's stated expectation | run each fenced read-only command and compare | `README.md:890` — `git ls-files \| grep env` is the **unanchored** pattern `CLAUDE.md` §10 records as always matching `envelope.ex`; it returns `.env.example` and `envelope.ex` on this tree, under `README.md:895`'s stated expectation of "no private `.env` files". The anchored form in `tools/gate.sh` returns 0 hits on the same tree. `:891`'s `grep key` returns nothing and is **not** an instance — the first draft of this cell cited the pair |
| a doc asserting a `main` SHA or a gate state that has moved | every `[0-9a-f]{7,40}` near `main`, and every gate-status table | `HANDOFF.md` §1's "`main` is at `5a6e566`" (now `86681a2`), its `test` row and its `248 tests` — cells carrying a slice-15 figure, each marked in place by slice 16k and none corrected. Cited by content, not by line — this table's own subject is citations that go stale, and two earlier drafts of this cell proved it, one citing `HANDOFF.md:17` after the same commit moved it to `:20`, the other quoting a string the same commit had deleted |

Slice 16k marked `HANDOFF.md` §1 **in place**, so a reader of §1 is warned at the point of
the falsehood rather than hundreds of lines later. The row above says which cells are only
flagged and which was corrected; this sentence repeats neither the list nor the count, because
review blocked here on exactly that repetition — a tally that disagreed with the
row, and then a summary that contradicted it. It is the class this entry is about, occurring
inside the entry about it.

## 15. What the baseline-gate pin covers, and what it does not

Slice 16k pins the `baseline` job by asserting its **entire body** — every non-comment,
non-blank line under `jobs:` → `baseline:`, whitespace collapsed — against a literal list in
`apps/hacktui_core/test/ci_baseline_guard_test.exs`, plus the requirement that `  baseline:`
occur exactly once under `jobs:`.

**It arrived at that shape the hard way.** Rounds 2 through 5 each pinned a *fragment* of the
job — the presence of one line, then the absence of two values, then a list of permitted
invocations, then lines containing `gate.sh` — and a reviewer walked past each one with a
working survivor: valid YAML, the suite green, and this required status check **green having
compared zero baselines**. The last of those was `bash tools/gate?sh baseline "$(printf …)"`,
which runs the gate and contains no `gate.sh` token at all. There is no token a respelling
must contain, because a shell word is resolved at run time and matched here at read time. Any
pin that first *recognises* a subset of the job and then rules on the subset can be spelled
around; a pin that asserts the whole body cannot, because every survivor adds or changes a
line. The mutants in `tools/mutants/c5.tsv` whose names begin `ci_baseline_` or
`gate_baseline_` are that history, and all die. **Which of them are reviewers' own survivors
is recorded in `HANDOFF.md` §10 by naming them.** Review blocked on a count here more than
once: each time a figure correct for one set was restated over a differently-drawn subset and
was off by one. Naming one population in one place removes the mechanism rather than the
instance.

**Covered — verified by mutant, each one KILLED:**

| lever | mutant |
|---|---|
| a second guard routing a trigger to the sentinel | `ci_baseline_second_guard` |
| the sentinel computed rather than written | `ci_baseline_computed_sentinel` |
| the command respelled (`bash tools/…`, extra whitespace, a glob) | `ci_baseline_bash_prefixed`, `ci_baseline_extra_space`, `ci_baseline_glob_spelling` |
| `continue-on-error: true` on the job | `ci_baseline_continue_on_error` |
| a job-level `if:` excluding a trigger | `ci_baseline_job_if_skip` |
| a trailing command swallowing the gate's exit code | `ci_baseline_trailing_true` |
| the job's `name:` changed — which changes its **check context**, and a required context that never reports blocks every pull request forever (`CLAUDE.md` §4c) | `ci_baseline_job_renamed` |
| the job key removed, or a second job of the same key added | `ci_baseline_duplicate_job_key` |

The `name:` row is worth reading twice. An earlier draft of this entry said a rename was
covered by the uniqueness assertion on the job **key**. Review measured that the key is not
the check context — `secret-scan` is the key, `Gate - tracked secret-shaped files` is the
context — so the edit that was covered could not break a required check, and the edit that
could break one passed green. The whole-body assertion covers both.

**NOT covered — everything outside the job's own body:**

- the `on:` block. Deleting `schedule:` or `workflow_dispatch:` means the gate never runs on
  that trigger at all. That is a different failure from reporting an unmeasured pass, but it
  is a way to make this gate stop saying anything.
- workflow-level `env:` (`LOGDIR`), the `concurrency:` group, and the shared
  `.github/actions/beam-setup` composite action.
- the branch-protection ruleset itself, which decides whether this context is required at
  all. Owner-only (`CLAUDE.md` §4c).
- every other `Gate -` job, none of which has an equivalent pin — and workflow-level
  `defaults:`, which this test does not read. What a `run.shell` override does to a job at
  run time is not measured here and is not claimed.
- **a second workflow file.** The test reads `.github/workflows/ci.yml` and nothing asserts
  that it is the only workflow (`ls .github/workflows/`). Whether a job of the same `name:` in
  another file would report under the same required context is not measured here and is not
  claimed; what is measured is that this pin would not see it.
- `tools/gate.sh`'s interior beyond the paths the tests exercise. The positive control (a real
  ref must produce a comparison) and the refusal tests cover the entry paths; the
  comparison loop itself is covered by `gate_baseline_*` mutants, not exhaustively.

This list is what has been **found**, not a proof of completeness. Successive review rounds
each found one more, and the honest summary is that it is a list of known levers, not a closed
set.

Extending the same whole-body assertion to the other `Gate -` jobs is the obvious next step
and is deliberately not slice 16k's work: it is one literal per job to maintain, and it should
be decided as one thing rather than smuggled in beside a fix to one of them.

## 16. The reviewable-diff recipe is still not canonical — several knobs move the hash

Slice 16l pinned `diff.renames` **and `diff.renameLimit`** in both copies of `DIFF_RECIPE`
(SCR-207). This entry records what that did **not** close.

`diff.renameLimit` was not in the original scope and is pinned because round 5 measured that it
**defeats a pinned `diff.renames=true` on the shipped, unmutated recipe**: with ambient
`diff.renameLimit=1` and three inexact renames staged, `grep -c 'rename from'` is `0` where the
pinned recipe gives `3`. Same tree, two hashes, and the rename-blind one at that. Pinning one
half of a two-part mechanism is not pinning it, so this is inside SCR-207's scope rather than an
expansion of it. `-c diff.renameLimit=0` means *unlimited* and overrides an ambient value — for
`git diff`. It does **not** override one for `git status`, measured, which is why the test's
fixture guard asks `diff --cached --name-status` instead.

**No total appears here, deliberately.** The set of knobs that move the hash is a function of
the *fixture* you test with, and successive sweeps of differing richness disagreed with each
other — see the traps below for the account. A count would be a claim about a census nobody has
taken. What follows is a **lower bound**: inputs measured to move it, each with the evidence.

**The candidate population, derived from git rather than recalled:**

```
git help -c | grep -E '^(diff|core)\.' | grep -vE '\.<'
```

**Then**: hash a fixture under the pinned recipe with and without each key, through **one
measurement path on both sides**, checking git's exit code, and trying **per-key value types**
rather than booleans only.

| knob | what it does to the bytes |
|---|---|
| `diff.mnemonicPrefix` | rewrites the path prefixes: `diff --git a/b.txt b/b.txt` becomes `diff --git c/b.txt i/b.txt` |
| `diff.suppressBlankEmpty` | drops the leading space from an **empty** context line — under `cat -A`, `" $"` becomes `"$"`. It does not touch a line whose content is a space |
| `diff.interHunkContext` | merges hunks that would otherwise stay separate, changing the `@@` headers |
| `diff.orderFile` | reorders the files in the diff entirely |
| `diff.indentHeuristic` | shifts hunk boundaries on indentation-sensitive insertions — measured by review; the author's fixture did not reproduce it, which is the fixture-dependence this entry is about |
| `core.attributesFile` | a path, not a boolean. Pointed at a file containing `*.txt -diff`, the diff body becomes `GIT binary patch` |
| `.git/info/attributes` | **not a config key at all.** Same effect, per-clone, and **no sweep over `git help -c` can ever find it** |

Every one is the failure mode SCR-207 records for `diff.renames`: same tree, different bytes,
different sha256, so a contributor whose config differs from CI's writes one `Reviewed-diff`
trailer while `Gate - attestation` derives another — and the gate goes red with nothing in its
output naming a config knob.

**The remedy is not another flag.** Pinning these one at a time loses the same race repeatedly;
the recipe should pin a **canonicalising set** in one deliberate change, with a test that
asserts invariance over the derived population rather than over one knob. Slice 16l is scoped
to `diff.renames` by SCR-207 and by its own PLAN, and expanding it silently is what §9 forbids.
`apps/hacktui_core/test/diff_recipe_test.exs`'s invariance test is named and scoped to rename
config for the same reason: broadening it would fail today, and that failure is this entry.

### Probe traps hit while deriving this, recorded because the numbers are worthless without them

A first sweep reported 49 movers; a second, 79; a third, one; a fourth, several. **Every one of
them was shaped by its harness or its fixture, the last included** — the fourth did not
reproduce `diff.indentHeuristic` and did not find `core.attributesFile`, both of which are in
the table above because review supplied them. The traps:

- **Exit codes unchecked.** git *erroring* on a value it rejects produces empty output, which
  hashes to something, which differs from the baseline. Errors counted as differences.
- **Two measurement paths.** A `printf '%s'`-captured candidate compared against a
  pipeline-computed baseline: `printf '%s'` strips the trailing newline the pipeline keeps, so
  every knob differed — from the harness, not from git.
- **A recalled fixture, and a boolean-only value set.** "A rename and a content change" has no
  blank context line, no widely separated hunks and no indentation-sensitive insertion, so
  knobs that only act on those read as inert. And a boolean sweep makes git reject
  integer-valued keys (`fatal: bad numeric config value 'true' for 'diff.interhunkcontext'`),
  after which a rule of "skip what git rejects" **discards them as knobs that do not move**.

- **A scrubbed environment cannot provoke the thing it scrubs.** Round 5's deepest finding, and
  it applies to any invariance test, not just this one. The test silences `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM` and `GIT_CONFIG_COUNT` so the caller's config cannot reach the fixture —
  necessary, for other reasons. But git's built-in default for `diff.renames` **is** `true`,
  which is exactly what the pin forces, so inside that environment a pinned recipe and an
  unpinned one emit byte-identical output. Three separate removals of the pin from shipped
  consumers therefore left the suite at `5 tests, 0 failures` while reddening attestation for a
  real contributor. **Running the artefact detects an inverted pin and is blind to an absent
  one.** The fix is a fixture whose OWN LOCAL config is hostile: local config is the one route a
  `GIT_CONFIG_*` scrub cannot close, since pointing those at `/dev/null` does not touch
  `.git/config`. Generalised: an invariance test must be able to FAIL for the default value of
  the thing it pins, or it is only testing agreement.

- **Value-space blindness.** The sweep varied each key over booleans. A key whose hostile value
  is a *path* — `core.attributesFile` — resolves to a nonexistent file under `true` and reads
  as inert. Given a real path it rewrites the body to `GIT binary patch`.
- **And the population is not the whole input.** `.git/info/attributes` has the same effect and
  is not a config key, so no derivation from `git help -c` can reach it. A sweep over a derived
  population is still a sweep over the population you thought to derive.
- **The input can arrive in the process environment, and can override a flag the recipe pins.**
  `GIT_DIFF_OPTS=-u7` overrides `-c diff.context=3`, which this recipe *does* pin — so the
  environment is not merely another delivery route for unpinned knobs, it can defeat pinned
  ones. `GIT_CONFIG_COUNT`/`_KEY_n`/`_VALUE_n` deliver config as if on the command line and are
  untouched by pointing the config files at `/dev/null`; measured, they cannot beat an explicit
  `-c`, but they reach anything unpinned. `XDG_CONFIG_HOME/git/attributes` and an untracked
  worktree `.gitattributes` are two more. None is a config key; no sweep finds any of them.

The population was derived; the *fixture* was recalled, the value space was assumed, and one
input was not a config key at all. That is the trap this entry exists to stop the next person
walking into.
