defmodule HacktuiCore.CiBaselineGuardTest do
  use ExUnit.Case, async: true

  # `Gate - baseline may only decrease` is a required status check. It is handed a git ref and
  # compares the baselines at that ref against the working tree's.
  #
  # `github.event.before` is ABSENT from the `schedule` and `workflow_dispatch` event payloads.
  # `${{ github.event.before }}` then expands to the empty string, and until slice 16k
  # `baseline_gate` matched the empty string in the same branch as the all-zeros sentinel:
  # it printed "no previous ref (new branch); nothing to compare" and returned 0.
  #
  # Measured, twice, before the fix:
  #
  #   run 34028977996  schedule           main                         778accb8  job SUCCESS
  #   run 34071415451  workflow_dispatch  slice/16k-baseline-trigger-guard 86681a2  job SUCCESS
  #
  # Both job logs contain `./tools/gate.sh baseline ""` followed by the "nothing to compare"
  # line. Both commits' parents carry `.claude/gate-baseline.json`, so a comparison was
  # available in each case and was not made. Nightly runs had been green on nothing.
  #
  # The correct guard already existed in `Gate - attestation`, above this one. This test holds
  # the two together so the baseline job cannot lose it again -- and so nobody re-derives a
  # second, differently-shaped guard for the same payload gap.
  #
  # It is an ordinary hard-blocking test, deliberately NOT a new `Gate -` job: a new required
  # context needs a ruleset edit only the owner can make (CLAUDE.md 4c), and a required context
  # that never reports blocks every pull request forever. Same reasoning slice 16c used for the
  # schema digest.

  @root Path.expand("../../..", __DIR__)
  @ci Path.join(@root, ".github/workflows/ci.yml")
  @gate Path.join(@root, "tools/gate.sh")

  @zeros "0000000000000000000000000000000000000000"

  # Lines of one top-level job, from `  <name>:` to the next key at the same two-space indent.
  # Line-based rather than YAML-parsed because the thing under test is the literal shell text
  # the runner executes, not a parsed structure: a YAML load would normalise the very bytes
  # the comparison is about.
  #
  # An earlier version of this comment justified it as "the repository has no YAML
  # dependency". That was false and review measured it -- `yaml_elixir 2.12.2` is in
  # `mix.lock` and loads in `:test`, and it parses this exact file. The reason above stands
  # on its own; the false one is deleted rather than left as the next reader's footgun.
  # Scoped to the `jobs:` mapping, and the key must occur EXACTLY ONCE inside it.
  #
  # Round 4 measured why both. `Enum.find_index` over the whole file takes the first
  # two-space-indented `baseline:` anywhere, and `env:` sits above `jobs:` -- so a
  # workflow-level env var named `baseline`, holding a multi-line plain scalar with the three
  # expected invocations in it, was found first. Every assertion in this file then passed
  # against a region that is not the job, while the real job routed the nightly to the
  # sentinel. Valid YAML, the suite green, the required check green on zero baselines.
  #
  # A pin that can be aimed at a decoy is not a pin. Scoping fixes the aim; the uniqueness
  # assertion fixes the aiming. The uniqueness assertion also catches a job RENAME, which is
  # worth having for its own sake: renaming a job renames its check context, and a required
  # context that never reports blocks every pull request forever (CLAUDE.md 4c).
  defp job(src, name) do
    # Split the way YAML does, not the way Elixir defaults to. YAML 1.2 §5.4 breaks lines on
    # LF, CR and CRLF; `String.split(src, "\n")` breaks only on LF. Round 6 measured what that
    # costs (pinned by `ci_baseline_cr_smuggled_line`, whose TSV row carries a real carriage
    # return -- a bare CR is not a terminator to the harness's reader, only CRLF is):
    # `# harmless note<CR>exit 0`, written as one LF-line, is ONE line here (dropped as
    # a comment) and TWO lines to a parser, the second an `exit 0`. Two independent parsers --
    # PyYAML and the `yaml_elixir` this repo ships -- agreed, and the whole suite stayed green
    # while the step exited 0 without ever invoking the gate.
    #
    # With this split that smuggled line is its own entry, is not in the allowlist, and fails
    # with the text quoted in the message. The fix is here rather than in a "reject CR" guard
    # because the defect was that this function's idea of a line disagreed with the runner's.
    all = String.split(src, ~r/\r\n|\r|\n/)

    jobs_at =
      Enum.find_index(all, &(&1 == "jobs:")) ||
        flunk("no top-level `jobs:` in .github/workflows/ci.yml")

    lines = Enum.drop(all, jobs_at + 1)
    occurrences = Enum.count(lines, &(&1 == "  #{name}:"))

    assert occurrences == 1,
           """
           `  #{name}:` occurs #{occurrences} times under `jobs:` in .github/workflows/ci.yml;
           exactly one is required. Zero means the job was renamed or removed -- which also
           renames its check context, and a required context that never reports blocks every
           pull request forever (CLAUDE.md 4c). More than one means this test cannot know
           which region it is reading, and a test that reads an ambiguous region is not
           evidence about either.
           """

    start = Enum.find_index(lines, &(&1 == "  #{name}:"))
    rest = Enum.drop(lines, start + 1)

    len =
      Enum.find_index(rest, &Regex.match?(~r/^  [A-Za-z_][A-Za-z0-9_-]*:/, &1)) ||
        length(rest)

    Enum.take(rest, len)
  end

  # Whitespace-insensitive comparison of the guard's shell text. A reformat is allowed; a
  # changed condition is not. Comment lines are dropped so the two jobs' prose may differ.
  defp guard_tokens(job_lines) do
    job_lines
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.filter(
      &(String.contains?(&1, "github.event.before") and
          String.starts_with?(String.trim_leading(&1), "elif"))
    )
    |> Enum.map(&(&1 |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")))
  end

  test "the baseline job guards the empty/sentinel payload exactly as the attestation job does" do
    src = File.read!(@ci)

    attestation = guard_tokens(job(src, "attestation"))
    baseline = guard_tokens(job(src, "baseline"))

    assert length(attestation) == 1,
           "expected exactly one `elif` guard on github.event.before in the attestation job, " <>
             "found #{length(attestation)}: #{inspect(attestation)}"

    assert length(baseline) == 1,
           "the baseline job has #{length(baseline)} `elif` guards on github.event.before; " <>
             "expected exactly one. Without it, `${{ github.event.before }}` expands to the " <>
             "empty string on schedule and workflow_dispatch and the gate reports a pass it " <>
             "never measured (runs 34028977996 and 34071415451)."

    # The condition, not the command: the two jobs pass different arguments to gate.sh.
    strip_body = fn [line] -> line |> String.replace(~r/;\s*then\s*$/, "") end

    assert strip_body.(baseline) == strip_body.(attestation),
           """
           the baseline and attestation guards have diverged.

             attestation: #{strip_body.(attestation)}
             baseline   : #{strip_body.(baseline)}

           One payload gap, one guard shape. If the condition genuinely needs to differ,
           that is a slice, not an edit.
           """
  end

  test "the baseline job is exactly the job this slice reviewed" do
    src = File.read!(@ci)

    # THE WHOLE JOB, not its invocations. Round after round of review got here, and the route
    # matters more than the destination, so it is recorded.
    #
    # Rounds 2 to 5 each pinned a FRAGMENT of this job and each was walked past by a reviewer
    # who produced a working survivor -- valid YAML, the suite green, and
    # `Gate - baseline may only decrease` GREEN having compared zero baselines:
    #
    #   r2  pinned "the sha~1 line is present"   -> a second guard made it unreachable
    #   r3  pinned "these two values are absent" -> `$(printf '0%.0s' $(seq 40))`
    #   r4  pinned "invocations are these three" -> `bash tools/...`; one extra space
    #   r5  pinned "lines containing gate.sh"    -> `tools/gate.s?`, which is the same file
    #
    # Each fix closed one spelling and the next round found another, because **every one of
    # them recognised a subset of the job and then made a rule about the subset.** A shell
    # word is resolved at run time and matched here at read time, so the two can always be
    # separated: `gate.s?`, `gate.$(printf sh)`, `$G`, a symlink. There is no token a
    # respelling must contain, and the round-4 comment claiming there was one was false.
    #
    # So stop recognising. This asserts the job's ENTIRE body -- comment lines and blanks
    # dropped, whitespace collapsed -- against a literal, and separately asserts that a
    # dropped line cannot execute (see the line-break guard below, which round 6 added after
    # a lone CR turned a dropped comment into an `exit 0`). There is then no subset to slip
    # through: a second guard, a respelled invocation, `continue-on-error: true`, a job-level
    # `if:`, a trailing `true` that swallows the exit code, a renamed `name:` that silently
    # breaks a required status check -- each adds or changes a line that survives the drop,
    # and any such line not in the list fails.
    #
    # The cost is real and is the point. Every edit to this job fails this test until the list
    # is updated in the same change. This job is a REQUIRED STATUS CHECK; it should not be
    # possible to change it quietly, and round after round of evidence says that when it is
    # possible, it happens.
    #
    # `expected` was generated from the file rather than retyped, then checked by making the
    # test fail once and reading what it printed.
    expected = [
      ~s(name: Gate - baseline may only decrease),
      ~s(runs-on: ubuntu-latest),
      ~s(timeout-minutes: 10),
      ~s(steps:),
      ~s(- uses: actions/checkout@v4),
      ~s(with:),
      ~s(fetch-depth: 0),
      ~s(- name: Compare against the ref this push started from),
      ~s(run: |),
      ~s(set +e),
      ~s(if [ -n "${{ github.base_ref }}" ]; then),
      ~s(git fetch --depth=1 origin \\),
      ~s("+refs/heads/${{ github.base_ref }}:refs/remotes/origin/${{ github.base_ref }}" \\),
      ~s(|| { echo "::error::cannot fetch base ref; refusing to pass unmeasured"; exit 1; }),
      ~s(./tools/gate.sh baseline "origin/${{ github.base_ref }}"),
      ~s(elif [ "${{ github.event.before }}" = "0000000000000000000000000000000000000000" ] || [ -z "${{ github.event.before }}" ]; then),
      ~s(./tools/gate.sh baseline "${{ github.sha }}~1"),
      ~s(else),
      ~s(./tools/gate.sh baseline "${{ github.event.before }}"),
      ~s(fi)
    ]

    raw = job(src, "baseline")

    # DROPPING A LINE IS ONLY SAFE IF A DROPPED LINE CANNOT EXECUTE, and until round 6 that
    # was assumed rather than asserted. The assumption is false as written: this test splits
    # on "\n", but YAML 1.2 §5.4 also breaks lines on CR and CRLF. One LF-line beginning with
    # `#` and containing a lone CR is ONE dropped comment here and TWO content lines to a
    # parser -- so `# note<CR>exit 0` was dropped by the pin and rendered as an `exit 0` in
    # the step's script. Measured by review against two independent parsers (PyYAML and the
    # `yaml_elixir` this repo already ships), with the suite green and the step exiting 0.
    #
    # So the drop is now guarded rather than trusted: the body must contain no character a
    # YAML parser treats as a line break other than the LF this test split on. With that
    # asserted, a line this test calls a comment is a comment to the runner too.
    # CR and CRLF are handled by the split in `job/2`. These three are YAML 1.1 line breaks
    # the split deliberately does not treat as such; a parser honouring them could still turn
    # one line here into two. Refused outright rather than split on, because no legitimate
    # line of this workflow contains them.
    breaks = %{
      "\u0085" => "NEL (U+0085)",
      "\u2028" => "LS (U+2028)",
      "\u2029" => "PS (U+2029)"
    }

    for {char, label} <- breaks do
      offenders = Enum.filter(raw, &String.contains?(&1, char))

      assert offenders == [],
             """
             the `baseline` job contains #{label}, which YAML treats as a line break and this
             test does not:

             #{Enum.map_join(offenders, "\n", &("  " <> inspect(&1)))}

             A line this test drops as a comment can therefore be two lines to the runner, the
             second of them executable. That is how a `# note` followed by a carriage return
             and `exit 0` passed every assertion in this file while making the step exit 0 --
             measured in round 6. CR is handled by splitting on it in `job/2`; #{label} is
             refused here because nothing in this workflow legitimately contains it.
             """
    end

    body =
      raw
      |> Enum.reject(&(Regex.match?(~r/^\s*#/, &1) or String.trim(&1) == ""))
      |> Enum.map(&(&1 |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")))

    assert body == expected,
           """
           the `baseline` job is not the job this slice reviewed.

           expected #{length(expected)} lines, found #{length(body)}. First difference:

           #{first_difference(expected, body)}

           This job is a required status check whose whole subject is refusing to report a
           pass it has not measured. Any line here that is not in the list above is
           unreviewed, and review found repeatedly that an unreviewed line in this job is how
           it goes green on zero baselines.

           If the change is legitimate, update the list in the same commit and say in the
           slice record what the job now compares. Comment lines and blank lines are ignored
           and whitespace is collapsed, so reformatting and commenting are free.
           """
  end

  defp first_difference(expected, body) do
    idx =
      Enum.find(0..max(length(expected), length(body)), fn i ->
        Enum.at(expected, i) != Enum.at(body, i)
      end)

    case idx do
      nil ->
        "(no line differs; the lists differ only in length)"

      i ->
        "  line #{i + 1}\n    expected: #{inspect(Enum.at(expected, i))}\n    found:    #{inspect(Enum.at(body, i))}"
    end
  end

  test "baseline_gate refuses an empty ref instead of passing on it" do
    src = File.read!(@gate)

    [branch] =
      Regex.run(
        ~r/^\s*if \[ -z "\$ref" \][^\n]*\n(.*?)^\s*fi$/ms,
        src,
        capture: :all_but_first
      ) || flunk("no `if [ -z \"$ref\" ]` branch in tools/gate.sh")

    # The capture is non-greedy to the first `^ fi$`. If the branch is ever rewritten as a
    # one-liner, `[^\n]*\n` swallows its `fi` and the capture runs on into the NEXT branch --
    # measured by review, which watched this assertion fail while printing the all-zeros
    # sentinel's body under a heading about the empty-ref branch. The verdict was right and
    # the evidence was of the wrong lines. Detect the slide instead of mis-reporting it.
    refute String.contains?(branch, "if ["),
           """
           the empty-ref branch capture slid past its own `fi` and swallowed a later branch:

           #{branch}
           This is a defect in THIS TEST's regex, not necessarily in tools/gate.sh. Re-anchor
           the capture before drawing any conclusion about the gate.
           """

    assert String.contains?(branch, "return 1"),
           """
           tools/gate.sh's empty-ref branch does not return 1. Its body is:

           #{branch}
           An empty string is not a git ref -- it only ever arrives from an event payload
           field that was not populated. A gate handed one has measured nothing.
           """

    refute String.contains?(branch, "return 0"),
           "tools/gate.sh's empty-ref branch still has a `return 0` path"

    # The all-zeros SENTINEL is a different value with a different meaning -- a push that
    # creates a branch -- and legitimately still passes. Pinned so the fix above is not
    # "simplified" by folding the two back together.
    assert Regex.match?(~r/\[ "\$ref" = "#{@zeros}" \]/, src),
           "tools/gate.sh no longer handles the all-zeros sentinel as its own case"
  end

  # Runs the gate. The assertions above read BYTES; the tests that call `run_gate/1` read
  # BEHAVIOUR, and those are the ones that cannot be satisfied by a file that merely looks
  # right.
  #
  # No count of them appears here, deliberately. Three drafts of this line carried one -- "the
  # only one of the four", then a tally of tests, then another -- and each was wrong, because
  # every disposition that added a behavioural test left the number behind. A comment that
  # miscounts the file it sits in is this slice's own subject; the cure is to state the
  # property and let `grep -c '^  test ' apps/hacktui_core/test/ci_baseline_guard_test.exs`
  # do the counting. No tally of this file appears in this file
  #
  # Both reviewers of round 1 broke the byte-only version, independently and by different
  # routes. Parking `[ -z "$ref" ] && { note ...; return 0; }` one line ABOVE the inspected
  # branch reinstates the pre-16k defect exactly -- measured, `rc=0` and "no previous ref
  # (new branch); nothing to compare" -- while leaving the inspected branch byte-identical, so
  # the text assertions stayed green. Returning 0 as `rc=0; return "$rc"` defeats the
  # `refute contains "return 0"` the same way. An unconditional bypass anywhere earlier in the
  # function is invisible to a regex scoped to one branch.
  #
  # That is CLAUDE.md 4b's own class -- "a gate reporting a verdict without running its
  # probe" -- committed inside the test written to prevent it. It is the reason this test
  # shells out rather than reads.
  #
  # `System.cmd/3` needs an ABSOLUTE path: a relative "./tools/gate.sh" with `cd:` raises
  # :enoent. LOGDIR is passed so gate.sh does not mktemp -d a directory nothing removes.
  #
  # Deliberately NOT asserted here: a real ref such as HEAD~1. `actions/checkout@v4` defaults
  # to fetch-depth 1 and the `Gate - test ratchet` job does not override it, so HEAD~1 does
  # not exist in the job this test runs in. Both cases below are answered before git is
  # consulted at all.
  defp run_gate(args) do
    tmp = Path.join(System.tmp_dir!(), "hacktui-16k-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      System.cmd(Path.join(@root, "tools/gate.sh"), args,
        cd: @root,
        env: [{"LOGDIR", tmp}],
        stderr_to_stdout: true
      )
    after
      File.rm_rf!(tmp)
    end
  end

  test "running the gate with an empty ref exits non-zero" do
    {out, rc} = run_gate(["baseline", ""])

    assert rc != 0,
           """
           `tools/gate.sh baseline ""` exited #{rc}. A required status check just reported a
           pass having compared zero baselines, which is the whole defect of slice 16k.
           Output:

           #{out}
           """

    assert out =~ "empty ref",
           "expected the refusal to name the empty ref; got:\n#{out}"
  end

  # The POSITIVE control, and it closes a gap review found rather than a defect review
  # measured. The tests beside this one assert that the gate REFUSES an empty ref and that the
  # sentinel PASSES; neither asserts that it ever actually compares anything. Round 6 pointed out that an
  # unconditional `return 0` placed after the sentinel branch leaves both of them green while
  # `baseline <real ref>` returns 0 having compared nothing -- the slice's own defect, moved
  # a few lines down the function.
  #
  # `HEAD`, not `HEAD~1`: `actions/checkout@v4` defaults to fetch-depth 1 and the
  # `Gate - test ratchet` job does not override it, so `HEAD~1` does not exist in CI. `HEAD`
  # always does, and comparing the committed baseline against the working tree's is a real
  # comparison of both keys. The assertion is that both keys are NAMED, not that they hold any
  # particular value: the values are the ratchet's and move without this test's leave.
  test "the gate actually compares when handed a real ref" do
    {out, rc} = run_gate(["baseline", "HEAD"])

    assert rc == 0, "`tools/gate.sh baseline HEAD` exited #{rc}:\n#{out}"

    for key <- ["credo_issues", "dialyzer_warnings"] do
      assert out =~ key,
             """
             `tools/gate.sh baseline HEAD` did not compare #{key}. Output:

             #{out}
             A gate that returns 0 without naming what it compared is the defect this slice
             exists to close, and the tests beside this one cannot see it, because they only
             exercise the paths that return before any comparison happens.
             """
    end
  end

  test "the all-zeros sentinel still passes, and says which case it took" do
    {out, rc} = run_gate(["baseline", @zeros])

    assert rc == 0,
           "the all-zeros sentinel is a real value with a real meaning (a push that creates " <>
             "a branch) and must keep passing; got rc=#{rc}:\n#{out}"

    assert out =~ "sentinel",
           """
           the sentinel path passed but did not identify itself as the sentinel. Before 16k
           one message -- "no previous ref (new branch)" -- covered BOTH this and the empty
           ref, which is how two different situations shared one verdict for as long as they
           did. Output:

           #{out}
           """
  end
end
