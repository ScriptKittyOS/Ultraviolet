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
