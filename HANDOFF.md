# HANDOFF

State for a session starting with no memory of the previous one. Everything here was
re-verified by command at write time; where a number came from a command, the command is
named so you can re-run it rather than trust it.

**Written:** 2026-09-02, after slice 13b. **Truth-synced:** 2026-09-02, slice 16 commit C1 —
§1, §2 and §7.1 were stale or wrong; see the correction notes in each.
**Governing rules:** `CLAUDE.md` (gitignored, at repo root). **Slice records:**
`internal/slices/NN-*/` (gitignored, local only). **Open work that must travel:**
`BACKLOG.md` (tracked, repo root). **Published residuals:** `docs/residuals.md`.

---

## 1. Where things stand

<!-- STALE as of slice 16k: `main` is at `86681a2`. See §10. Not corrected here; the
     documentation-drift sweep is its own unit of work, BACKLOG.md §14. -->

`main` is at **`5a6e566`** (slice 15, the commit that added this file). The suite is
**248 tests, 0 failures** <!-- STALE as of slice 16k: the figure here is from slice 15. Derive the current one --
     `mix test 2>&1 | grep -oE '[0-9]+ tests?, [0-9]+ failures?' | awk -F'[ ,]' '{t+=$1;f+=$4}
     END{print t" tests, "f" failures"}'` -- rather than reading a transcribed number.
     See §10 and BACKLOG.md §14. --> — green for the first time. Re-derived at slice 16 rather than
carried forward: `mix test` summed across the umbrella apps gives 248/0, and it reconciles
with CI's advisory integration job (266 tests when `--include integration` adds the 18
integration-tagged ones; 266 − 18 = 248).

| Gate | Baseline | State |
|---|---|---|
| compile `--warnings-as-errors` | — | pass, hard-blocking |
| format `--check-formatted` | — | pass, hard-blocking |
| tracked secret-shaped files | — | pass, hard-blocking |
| test | **0** | **STALE — see §10.** This row predates slice 16: `tools/gate.sh` scores `test` with `hard_zero`, and the baseline entry is retired. Not corrected here; BACKLOG.md §14 |
| credo `--strict` | **76** | held |
| dialyzer | **43** | held |
| deps.audit / hex.audit | 12 / 20 | advisory, not blocking (**slice 18**'s work) |
| mutation (`tools/mutate.sh`) | 0 survivors | **STALE — see §10.** This figure is from slice 15; `./tools/mutate.sh tools/mutants/c5.tsv \| tail -2` gives the current one. CANARY aborts |
| attestation | — | **GREEN on `main`** — run 33594696902; see §2 |

Slices 01 through 13b, and 15, are merged. **14 is not** — it has a PLAN and CRITERIA and
**no code**, and it is blocked (§5); no commit in history references it
(`git log --oneline | grep '^[0-9a-f]* 14-'` → empty). Slice 16 is the release (§6), 17 is
presentation (§7), 18 is the audit advisories.

A ratchet at 0 is **not** the same as a hard gate: `baseline_gate()` permits a raise when a
matching `_corrections` entry ships in the same diff, so failing tests could land by raising
the baseline with a recorded reason. Slice 16 closed that for `test` by deleting the entry, so
it no longer applies to tests — it still applies to `credo` and `dialyzer`. Find the logic
with `grep -n _corrections tools/gate.sh` rather than a line number: the citation that used to
stand here was accurate when written and was invalidated by the very commit that hardened the
gate, which is what line numbers into a file under active change are worth.

## 2. The red gate that healed itself, and why it was never a bug

**Outcome, recorded 2026-09-02:** this resolved exactly as predicted below. The next
rebase-merged commit, `5a6e566`, had range `bbc4372..5a6e566`, which **excludes** `bbc4372`,
and `main` went green on run **33594696902** with no allowlist, no revert and no history
rewrite. What follows is the original analysis, kept because the reasoning is the reusable
part; the forecast in it is now a measured outcome.

`Gate - attestation` failed on `bbc4372` (run **33592712829**).

`tools/gate.sh attestation` re-derives each commit's diff hash and compares it to the
`Reviewed-diff` trailer in that commit's message. `bbc4372` was created by **squash**-merging
PR #2: its diff is the *union* of the branch's commits, but its message inherited a trailer
from one of them.

    claimed (inherited):  13612c79b39396721e7a65af393b4dc71cf951ae9905cf80865a1d945048b39b
    derived (union diff): 9e4e0f6251a43b0b552239e209421b720ce9733123dbc1f0f7ec490772dd2203

**The gate is working correctly.** It is reporting, accurately, that a commit on `main` does
not attest to its own diff. The design assumed commits survive; squash rewrites them.

**Do not "fix" this with an allowlist or a revert.** History cannot be rewritten
(non-fast-forward, no bypass actors — deliberate), and a revert would be one more
trailer-less commit. Both gate paths are already **bounded ranges**, verified:

    push:        github.event.before..github.sha
    pull_request: origin/<base>..github.event.pull_request.head.sha
    new branch:  github.sha~1..github.sha

Neither scans history. So the next rebase-merged commit has range `bbc4372..new`, which
**excludes** `bbc4372`, and `main` goes green on its own. If you find either path scanning
all history, that is a real defect — fix it.

**Recurrence is prevented at the platform**, not by convention. Ruleset 22066749, verified
by API immediately before this commit:

    allowed_merge_methods:   ["rebase"]
    required_linear_history: true
    enforcement: active   bypass_actors: []   (administrators are not exempt)
    deletion + non_fast_forward blocked, PR required, strict: true
    9 required contexts == 9 live "Gate -" jobs, exact match

Merge method is **rebase**. Squash or merge-commit on an attested branch is a defect.

## 3. Probes are the thing that keeps failing — read this before experimenting

Three times a *probe* gave a wrong answer while the change under test was fine. This is why
`CLAUDE.md` §4b exists.

1. **A probe reported IDENTICAL over two empty lists.** Testing whether SPDX headers change
   compiled output, in a fresh worktree with no `_build`, so `find` matched nothing and two
   empty files compared equal. The real answer, measured across 2,211 beams, is that headers
   **do** change raw `.beam` output because `debug_info` embeds line numbers.
2. **Three mutations never applied and were scored as survivors.** Regex escaping silently
   failed to match, so the harness measured unmutated code and reported a perfect-looking
   result. `tools/mutate.sh` now proves application three ways and aborts on a CANARY row
   whose pattern is deliberately absent.
3. **`:beam_lib.strip/1` writes the stripped beam back to disk.** It is not a pure function.
   A stripped-equivalence experiment stripped `debug_info` out of the real `_build/dev`, and
   dialyzer then failed with "Could not get Core Erlang code". Fixed by a clean rebuild.

**Standing rule (CLAUDE.md §4b): probes run against a copy.** Any experiment touching
`_build`, `deps`, `.git` or tracked files runs in a throwaway worktree or a copied `_build`,
never the working one, and **the PLAN names where the probe runs before it runs.**

## 4. Order of work

**Release (16), then licensing (14) when unblocked, then presentation (17).** Nothing else
starts until the tag exists. The audit advisories are **slice 18**. Numbering settled at
slice 16 planning time: 15 is spent on this file, so the release is 16, not 15.

Slice 14 is **blocked** on two inputs only the owner can supply: the exact registered entity
name, character for character, and the copyright assignment date.

## 5. Slice 14 — licensing, planned and blocked

One commit changes `LICENSE`, `NOTICE`, and SPDX headers on all ~273 tracked files.

- Headers: `SPDX-FileCopyrightText: 2026 <registered name>` — **holder only**. The header is
  a rights statement, not a credit line.
- `LICENSE` and `NOTICE` copyright line become the holder.
- `NOTICE` additionally carries the builder credit and the original author and inventor with
  ORCID `0009-0008-9457-2160`. NOTICE is the file Apache-2.0 requires downstream users to
  preserve, so that is where builder and author names travel with the code.
- `PROVENANCE.md`: authorship, build name, assignment with date, developed at private
  expense, patent holder.

**Its exit criterion was corrected, and the correction matters.** "Byte-identical `.beam`
output" **cannot pass** — `debug_info` embeds line numbers, so two header lines shift every
module. Three independent proofs replace it:

1. **Stripped-beam equivalence** — compare with debug and line chunks removed. Verified
   **IDENTICAL across 2,178 beams**. Proves semantics unchanged. *Strip against a copy.*
2. **Diff-shape** — every added line is a comment, nothing removed or modified. Provable
   from the diff alone, so a reviewer needs no build.
3. **Count assertion** — every in-scope file gained exactly one header and none gained two,
   so re-running the script cannot silently double up.

## 6. The release slice (16) — five blockers, four confirmed and one to re-measure

`mix release` does not boot today. None of these is the manual `ensure_all_started` sequence
the docs imply; every app already declares a proper `mod:`.

1. `config/runtime.exs` raises unconditionally in `:prod` — `HACKTUI_START_REPO` defaults
   false, so the guard errors before any application starts.
2. With env set, `start_repo: true` makes `Repo` a permanent child; an unreachable DB halts
   the release. **Not re-measured, and doubted.** `store/supervisor.ex:17-24`
   (`maybe_repo_child/0`, which adds `HacktuiStore.Repo` at line 20) adds `Repo` as
   an ordinary `:one_for_one` child and Postgrex normally starts and retries rather than
   failing `start_link/1`, so the node may well survive. Slice 16 measures this in a
   container before fixing it; if it survives, this blocker is recorded as corrected and
   replaced by whatever the real fresh-machine failure turns out to be.
3. The `hacktui_sensor` release contradicts its own comment: its `.app` lists `hacktui_hub`,
   which pulls `hacktui_store`, so the standalone sensor also demands DB credentials.
4. No TUI entry point exists in a release — the only path to the dashboard is a Mix task,
   and Mix is not in a release.
5. `config/config.exs` reads `System.get_env` at **build** time, baking build-host DB values
   into `sys.config`.

**Exit, two tiers, both measured in a container with no cached `_build` and no cached
`deps`:** **Tier 0** (no Postgres) boots from a clean clone with no manual sequence, passes
the README health checks, and serves an MCP `initialize` over stdio. **Tier 1** (same
container plus the README's one-line Postgres command) reaches alerts, cases and the full
TUI. Then a **signed, annotated** `v0.1.0` tag, created from a fresh container run against
the merged `main` commit, and a **GitHub Release** whose notes list what is qualified, link
`docs/not_production_ready.md`, and state the licence. Slice 14 has not run, so the notes
make no SPDX/REUSE claim. Exact commands and their output go in the signoff.

## 7. Repo presentation (slice 17) — eight items

1. **README "currently supports" must match the code.** *Corrected twice; the second
   correction is the one to trust.* There are **three** collectors, not one —
   `Collectors.Network` (`collectors/network.ex`), `Collectors.ProcessSignals`
   (`hacktui_sensor.ex:75`) and `Collectors.Journald` (`hacktui_sensor.ex:170`). All three
   are wired and supervised, so the test "name the module that does it or drop it"
   **passes for all three** and the bullets are not false.

   **The earlier version of this item paired the wrong collectors with the wrong variables.**
   It said "both non-network collectors are opt-in via `HACKTUI_SENSOR_JOURNALD` /
   `HACKTUI_SENSOR_NETWORK`" — which names a NETWORK variable while claiming to describe the
   non-network collectors, and which credits `ProcessSignals` with a gate it does not have.
   Read at `5a6e566`:

   | Collector | Gate | Variable |
   |---|---|---|
   | `Collectors.Network` | `enabled?:` (`hacktui_sensor.ex:49`) | `HACKTUI_SENSOR_NETWORK`, default off |
   | `Collectors.Journald` | `enabled?:` (`hacktui_sensor.ex:67-68`) | `HACKTUI_SENSOR_JOURNALD`, default off |
   | `Collectors.ProcessSignals` | **none — started unconditionally** | **none existed**; `process_signal_opts/0` (`:54-60`) takes only `interval_ms` |

   The real defect stands and is worse than "one collector": neither variable appears in any
   **user-facing** documentation — nothing under `docs/`, not `README.md`, not `.env.example`.
   Before this commit, `grep -rn HACKTUI_SENSOR` over the repo hit only `hacktui_sensor.ex`
   and this file; it now also hits `BACKLOG.md`, which is process text, not a runbook. A
   reader following the docs still cannot enable journald or network capture.

   **Moved into slice 16**, because a release that boots from a clean clone has to be one
   where a reader can enable what the README says is supported. Slice 16 adds
   `HACKTUI_SENSOR_PROCESS_SIGNALS` (**default on**, so today's behaviour is unchanged for
   anyone running now), documents all three in `docs/runtime_modes_matrix.md` and
   `.env.example`, and adds a per-collector test asserting each variable starts exactly its
   own collector and that a docs row exists for each — so code and docs cannot drift again
   without `mix test` noticing. Also note that two collectors are structurally hidden inside
   the parent module, which is why they read as absent.
2. **Label detection as scaffolding.** `DetectionService` is a thin delegate; no rule layer,
   no rule format, no coverage table. `attack_mapping/1` (`purple_service.ex:28-29`) is two
   clauses — `T1071.004` for `"alert_observed"` and a `T1087` fallthrough. Add a status note
   to `PURPLE_TEAM_MODEL.md` so it does not imply detection validation exists, and a TODO on
   `attack_mapping/1` marking it a placeholder.
3. **`docs/standards_mapping.md`, design intent only.** Observation kinds to OCSF event
   classes (`network.flow`, `journald.auth`, `journald.security`, `system.error`); alerts and
   cases to OCSF findings; `contain`/`observe`/`notify_export` to CACAO action types;
   receipts as the evidence attachment on an alert. Mark explicitly as mapping, not
   implementation. No code changes.
4. **`ROADMAP.md`: move "proof-carrying alerts and investigations" from Later to Next.**
   Confirmed at line 42 under `## Later`. It is the HolyTrinity hook and the thing that makes
   this an agent-incident-response console rather than a SOC prototype.
5. **Consolidate three demo runbooks into one** — keep `docs/case_1_demo_runbook.md` as the
   walkthrough; fold in `docs/demo_runbook.md` and `docs/demo_terminal_launcher.md`.
   `docs/README.md` already flags them as overlapping.
6. **Release**: covered in §6, and it is slice **16** — it runs before this list, not inside it.
7. **Repo presentation**: About text — *"Terminal-native purple-team SOC on the BEAM. Agents
   propose; a human approves; every effect is auditable."* Topics: `elixir`, `erlang`,
   `beam`, `security-operations`, `soc`, `purple-team`, `mcp`, `ai-agents`, `jido`,
   `apache-2`. Add `SECURITY.md` (how to report, what is in scope), `CITATION.cff` (name,
   ORCID `0009-0008-9457-2160`, version, date), `CHANGELOG.md` seeded from slice history.
   Badges limited to what is true: licence, and CI status from the real gate workflow.
8. **GitHub-setting dependencies are owner work, flagged in the PLAN, never discovered at
   signoff.**

## 8. Owner work — cannot be done from the repo

- GitHub **About** text and **topics** (§7.7).
- **Social preview** image.
- **Publishing** the GitHub Release. *Corrected:* the working session's credentials are
  sufficient to create a release, so `gh release create` **would** succeed from the repo. It
  is owner work by decision, not by capability. The agreed protocol: the notes are drafted in
  the signoff, the owner reads
  them, the owner replies with the single word `publish`, and only then is the staged
  command run. Not on inference.
- **Signing config and the GPG key.** `user.signingkey`, `tag.gpgsign`, `commit.gpgsign` and
  `gpg.format` are all unset in this repo, so `git tag -s` would guess. The owner sets them
  and publishes the public key to GitHub; the key's fingerprint is in the slice 16 PLAN
  rather than here, because publishing it commits to an identity linkage that is the owner's
  call to make. Uploading a key needs a token scope the working session deliberately does
  **not** hold, and that is **not** widened for the release.
- The **registered entity name and assignment date** for slice 14.
- Raising `required_approving_review_count` above `0` and naming `required_reviewers`, if
  §0 is ever to be enforced by the platform rather than by process.

## 9. Things that will bite you

- **`internal/` is gitignored.** Slice PLANs, CRITERIA, FINDINGS and signoffs are local
  only and are not in the published repo. A commit touching only `internal/` stages nothing
  and `commit-msg` will refuse it as "nothing to attest". **This file was itself the lesson:
  gitignored planning does not travel.** `BACKLOG.md` (tracked, repo root, added in slice 16)
  is where open work that must survive a clone now lives. Three **tracked** files were already
  citing it before it existed — `.githooks/commit-msg:11`, `.claude/gate-baseline.json:12`, and
  `apps/hacktui_agent/lib/hacktui_agent/mcp/egress.ex:16` — and `CLAUDE.md` cites it in several
  sections (that count is not independently checkable, since `CLAUDE.md` is gitignored and has
  no history). The `egress.ex` one matters most: a dangling reference to a missing file is
  merely untidy, but once the file exists the reference becomes **checkable**, so every citation
  now needs a real item to land on.
- **`internal/incoming/holytrinity.hold-v1.schema.json`** is parked, awaiting the contracts
  slice. It lives there because an untracked `schemas/` blocked the commit gate four times.
- **Renaming a `Gate -` job silently breaks a required check** in the ruleset, and a
  required context that never reports blocks every PR forever. Any slice that renames one
  must put the before/after context names in its PLAN so the ruleset edit is a copy-paste.
- **The integration job is advisory and fails.** *Corrected in slice 16; the earlier "3
  failures, none of them tagged `:integration`" was wrong on both counts.* Measured on run
  **33594696902** (the push run for `5a6e566`): **four** failures — `HacktuiStoreTest` (1),
  `HacktuiHub.SafeModeSmokeTest` and `HacktuiHub.ReplayIngestTest` (2), and
  `HacktuiAgent.InvestigationFlowDbIntegrationTest` (1). **Do not carry a fixed count
  forward**: it varies run to run, so re-derive it from the job log rather than quoting this
  line.

  **There is no single root cause, and every attempt to state one has been wrong.** The
  explanation to stop repeating: "the job sets `HACKTUI_START_REPO=true`, so repo-disabled
  tests fail" is **false** — `config/runtime.exs:15` is `if config_env() != :test do`, so that
  variable is never read in the test environment. The workflow sets it; it does nothing.

  What `--include integration` really does is **add** to the selection rather than narrow it,
  so integration tests share a BEAM with everything else and mutate global state the untagged
  tests depend on. **That is the enabling condition, and it is as far as the established
  explanation goes.** These are order-dependent failures, and every attempt so far to state a
  per-test causal chain has been wrong in some detail — the last one asserted that nothing
  restarts `:hacktui_hub` when several untagged modules do. Counts are what keep going stale
  here; derive them, do not quote them.

  So: `HacktuiStoreTest` finds a live repo because `:start_repo` is already true and
  integration setup does not restore it; `SafeModeSmokeTest` fails
  `assert hub.supervisor_started?`, which is a supervisor check and not a repo assertion, and
  is unusual in asserting hub state without starting the application first;
  `ReplayIngestTest` fails on `audit_id: "has already been taken"` against a non-idempotent
  fixture; and `InvestigationFlowDbIntegrationTest` is tagged (`@moduletag :integration`,
  line 6) and fails a timeline-entry match, so the tagging work cannot clear it.

  **Re-derive before acting.** Full breakdown, with what is and is not established, in
  `BACKLOG.md` §2.
- **Reviewers get `CRITERIA.md` before they are spawned**, and must classify every finding
  as blocking or residual. A round finding only residual items is PASS-with-residuals.
  Three-round cap unless a blocking class is hit. An unclassified finding is not actionable.

---

## 10. Slice 16k — the baseline gate no longer passes unmeasured (SCR-69, first half)

`Gate - baseline may only decrease` is a required status check. `github.event.before` is
**absent from the `schedule` and `workflow_dispatch` event payloads**, so
`.github/workflows/ci.yml` expanded to `./tools/gate.sh baseline ""` and `baseline_gate`
matched the empty string in the same branch as the all-zeros sentinel: it printed
`no previous ref (new branch); nothing to compare` and returned **0**. Every nightly run in
this repository's history was green having compared zero baselines.

Measured before any fix, from the job logs (`gh api repos/ScriptKittyOS/Ultraviolet/actions/jobs/<id>/logs`):

| run | event | head | job | result |
|---|---|---|---|---|
| `34028977996` | `schedule` | `778accb8` | `101474937084` | success, 0 comparisons |
| `34071415451` | `workflow_dispatch` | `86681a2` | `101589359652` | success, 0 comparisons |

A comparison was available in both cases — each head's parent carries
`.claude/gate-baseline.json`.

**The fix reuses a guard that already existed.** `Gate - attestation` handles the identical
payload at the `elif` in its own `run:` block, and in run `34028977996` (job `101474937083`)
it measured while the baseline job did not. The same `elif` now sits in the `baseline` job,
routing an empty-or-sentinel `before` to `${{ github.sha }}~1`; `baseline_gate` **refuses an
empty ref outright**. The all-zeros sentinel keeps its pass as its own labelled case and is
now unreachable from CI.

**Where the guarantee actually lives.** `apps/hacktui_core/test/ci_baseline_guard_test.exs`
is an ordinary hard-blocking test — **no new `Gate -` job**, so no ruleset change (§4c), the
same reasoning slice 16c used for the schema digest. Its tests that call `run_gate/1` **run the gate**
rather than reading it, and those are the ones that cannot be satisfied by a file that merely
looks right. (Drafts of this sentence carried a count of them and each was wrong, because
every disposition that added one left the number behind. The property is stated and no count
of them appears here.) Round 1 shipped only the reading
assertions and both reviewers broke them independently: parking
`[ -z "$ref" ] && { note ...; return 0; }` one line above the inspected branch reinstates the
pre-16k defect exactly while leaving that branch byte-identical, and all text assertions
stayed green. That mutation is now row `gate_baseline_early_bypass` in
`tools/mutants/c5.tsv`, and it dies.

**Numbers this slice moves** (the §1 table above predates it and is not updated here —
see "still stale" below):

- mutation harness: **no survivors.** The count of rows, the split between reviewer survivors
  and derived rows, and the totals before and after are **not transcribed here** — they go
  stale the moment a row is added, and review kept blocking on exactly that. Derive them:

  ```
  ./tools/mutate.sh tools/mutants/c5.tsv | tail -2
  git diff <base> -- tools/mutants/c5.tsv | grep '^+[a-z]' | cut -f1   # the rows this slice adds
  ```

  **Which rows are reviewer survivors** — a lane demonstrated each defeating the pin, and the
  row is the receipt: `gate_baseline_early_bypass`, `ci_baseline_second_guard`,
  `ci_baseline_computed_sentinel`, `ci_baseline_bash_prefixed`, `ci_baseline_extra_space`,
  `ci_baseline_glob_spelling`, `ci_baseline_cr_smuggled_line`,
  `gate_baseline_post_sentinel_bypass`.

  **Which rows this slice adds are derived**: `ci_baseline_guard_route`, `ci_baseline_guard_condition`,
  `gate_baseline_empty_ref_passes`, `ci_baseline_duplicate_job_key`,
  `ci_baseline_trailing_true`, `ci_baseline_continue_on_error`, `ci_baseline_job_if_skip`,
  `ci_baseline_job_renamed`. Both lists are of the rows THIS SLICE ADDS; the rows that predate
  it are neither. Naming them is durable; counting them was not, and saying "the remainder"
  was not either — over the whole file it mislabels every row the slice did not write.

**Still open, deliberately.** SCR-69's other half: a force-push sets `github.event.before` to
a well-formed but **unreachable** SHA, which is not the sentinel, so `git cat-file -e` fails
and the gate goes **red on a tree that is fine**. Opposite failure direction, different
remedy, out of 16k's scope. Recorded in `BACKLOG.md` §13 with the corrected evidence.

**Still stale, and NOT fixed by this slice.** §1 above says `main` is at `5a6e566`; it is at
`86681a2`. §1's gate table described `test` as a ratchet awaiting retirement, which slice 16
completed, and its suite and mutation numbers are likewise from slice 15. Each such cell now
carries an inline STALE marker, so a reader of §1 is warned at the point of the falsehood.
These are instances of a documentation-drift class being derived and swept as its
own unit of work; fixing them here would have been silent scope expansion (§9).
Do not read §1's numbers as current.
