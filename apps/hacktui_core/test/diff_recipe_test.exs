defmodule HacktuiCore.DiffRecipeTest do
  use ExUnit.Case, async: true

  # The reviewable-diff recipe decides what a commit's attestation covers. It has ONE
  # definition, in tools/gate.sh (`DIFF_RECIPE` and `DIFF_SCOPE`), read by `derive_diff_hash`
  # for the attestation gate and by `staged_diff_hash` for .githooks/pre-commit and
  # tools/signoff.sh.
  #
  # .githooks/commit-msg still carries a second copy. It runs in a context where sourcing
  # tools/gate.sh is a behaviour change, so removing that copy is slice 17's work. Until then
  # the two are held together HERE rather than on faith: if they drift, the trailer a commit
  # writes stops matching the hash the gate derives, and `Gate - attestation` goes red on main
  # for a reason nobody would connect to an edit in a hook.
  #
  # One copy is the goal. Two copies with an equality gate is the acceptable interim. Two
  # copies on faith is the defect class this repository keeps re-finding -- and a grep COUNT
  # is not proof, because two byte-identical copies pass a count. This test compares the token
  # sequences, so a change to either side fails it.
  @root Path.expand("../../..", __DIR__)
  @gate Path.join(@root, "tools/gate.sh")
  @commit_msg Path.join(@root, ".githooks/commit-msg")
  @pre_commit Path.join(@root, ".githooks/pre-commit")

  defp tokens(s), do: s |> String.split(~r/\s+/, trim: true)

  # `DIFF_RECIPE=(-c diff.noprefix=false ...)` -> the tokens between the parentheses.
  # `^` alone was blind to an indented duplicate -- and bash executes an indented assignment
  # exactly like a column-0 one, so `  DIFF_RECIPE=(-c diff.context=9)` inserted before
  # DIFF_SCOPE changed the hash the gate produces while this test still reported 3 tests, 0
  # failures. A canary that a real duplicate walks past is not a canary. `^[ \t]*` counts them.
  defp array(src, name) do
    case Regex.run(~r/^[ \t]*#{name}=\((.*)\)\s*$/m, src, capture: :all_but_first) do
      [body] -> tokens(body)
      _ -> flunk("#{name}=(...) not found in tools/gate.sh, or spans more than one line")
    end
  end

  # Comment lines are stripped, then assignments are counted. The forms this matcher is known to
  # count and known not to count are listed in the test below; it is a matcher, not a bash parser.
  defp non_comment(src) do
    src
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  # `NAME=(`, `NAME+=(` and `NAME[i]=` are all assignments bash executes. Counting only `=(`
  # was the THIRD form-blindness in this one construct: `^` missed an indented duplicate,
  # `^[ \t]*` missed `;`/`then`/`eval`, and this missed `+=` and `[i]=` — each time while the
  # duplicate measurably moved the hash the gate produces and the canary reported one
  # definition. The forms are now covered by a test rather than by the next reviewer.
  # An ASSIGNMENT, not a use: the bracket form must close and be followed by `=`, and `$`/`{` are
  # excluded from the lookbehind, so `"${NAME[@]}"` does not count. Measured: without that, this
  # test reported 3 definitions of a variable defined once, counting the two array expansions in
  # derive_diff_hash and staged_diff_hash.
  defp count_defs(src, name) do
    length(Regex.scan(~r/(?<![A-Za-z0-9_${])#{name}(\+?=\(|\[[^\]]*\]\+?=)/, non_comment(src)))
  end

  test "tools/gate.sh defines the recipe exactly once" do
    src = File.read!(@gate)

    for name <- ["DIFF_RECIPE", "DIFF_SCOPE"] do
      count = count_defs(src, name)

      assert count == 1,
             "tools/gate.sh has #{count} definitions of #{name}; exactly one is the point. " <>
               "Two byte-identical copies pass a grep count, so the only honest test is a " <>
               "mutation, and a mutation needs exactly one thing to mutate."
    end
  end

  # Nine forms, measured: six that bash executes and the counter counts, three inert ones it does
  # not. Regression locks for forms this file has been bitten by. Asserted against synthetic
  # source rather than by mutating the real file, so they run in the ordinary suite.
  test "nine known assignment forms: six counted, three not" do
    base = "DIFF_RECIPE=(-c diff.context=3)\n"

    live = [
      {"plain second definition", "DIFF_RECIPE=(-c diff.context=9)"},
      {"indented", "  DIFF_RECIPE=(-c diff.context=9)"},
      {"after a semicolon", "true; DIFF_RECIPE=(-c diff.context=9)"},
      {"after then", "if true; then DIFF_RECIPE=(-c diff.context=9); fi"},
      {"append with +=", "DIFF_RECIPE+=(-c diff.context=9)"},
      {"element assignment", "DIFF_RECIPE[1]=--patience"}
    ]

    for {label, form} <- live do
      assert count_defs(base <> form <> "\n", "DIFF_RECIPE") == 2,
             "the counter does not see a duplicate #{label} (#{inspect(form)}), " <>
               "which bash executes."
    end

    # Three inert forms. A counter that matched everything would fail these.
    assert count_defs(base <> "#  DIFF_RECIPE=(-c diff.context=9)\n", "DIFF_RECIPE") == 1,
           "a duplicate quoted inside a comment is inert and must not count"

    assert count_defs(base <> "MY_DIFF_RECIPE=(-c diff.context=9)\n", "DIFF_RECIPE") == 1,
           "a longer variable name that merely ends in DIFF_RECIPE must not count"

    assert count_defs(base <> ~S|  git "${DIFF_RECIPE[@]}" diff --cached| <> "\n", "DIFF_RECIPE") ==
             1,
           "an array EXPANSION is a use, not a definition, and must not count"
  end

  test ".githooks/pre-commit holds no copy of the recipe" do
    refute File.read!(@pre_commit) =~ "diff.noprefix",
           ".githooks/pre-commit carries its own copy of the diff recipe again. It should call " <>
             "`./tools/gate.sh staged-diff-hash` instead."
  end

  test ".githooks/commit-msg's recipe is token-identical to the one in tools/gate.sh" do
    gate = File.read!(@gate)
    recipe = array(gate, "DIFF_RECIPE")
    scope = array(gate, "DIFF_SCOPE")

    # Join continuations, then compare token sequences -- not a
    # substring match, which is what fails on line-wrapped text (slice 16b, three times).
    src = File.read!(@commit_msg)

    # Anchored at `staged=$(`, NOT at the `git` token. Round 3 measured why: with the capture
    # starting at `git`, everything between the assignment and that token was invisible, and
    # `staged=$(GIT_DIFF_OPTS=-u7 git ...` passed while beating the pinned `-c diff.context=3`.
    # A `cd` in the same position was equally invisible.
    invocation =
      case Regex.run(~r/staged=\$\((.*?)\|\s*sha256sum/s, src, capture: :all_but_first) do
        [inv] -> inv |> String.replace("\\\n", " ") |> tokens()
        _ -> flunk(".githooks/commit-msg: could not find the `git ... | sha256sum` invocation")
      end

    expected = ["git"] ++ recipe ++ ["diff", "--cached"] ++ scope

    assert invocation == expected, """
    .githooks/commit-msg and tools/gate.sh disagree about the reviewable-diff recipe.

      commit-msg: #{Enum.join(invocation, " ")}
      gate.sh:    #{Enum.join(expected, " ")}

    These two must produce byte-identical diffs: commit-msg writes the Reviewed-diff trailer
    and tools/gate.sh derives the value CI compares it against. A drift here turns every new
    commit red on `Gate - attestation`. Change both, or finish removing the copy (slice 17).
    """
  end

  # THE PROPERTY, not the spelling. Everything above pins that the two copies AGREE and that
  # there is exactly one of each; none of it pins what the recipe actually does. Drop
  # `-c diff.renames=true` from BOTH copies and every assertion above still passes, because
  # they would still agree -- about the wrong thing.
  #
  # That is the shape a sibling repository's reviewers broke twice in one round: an assertion
  # about a literal spelling standing in for an assertion about a property. So this one runs
  # the recipe.
  #
  # It builds a rename-bearing repository WHOSE OWN LOCAL CONFIG IS HOSTILE, and requires the
  # shipped recipe to detect renames anyway. `git` reads `diff.renames` from config when the
  # command line does not pin it, so without the pin the fixture's config wins and the diff
  # carries no rename at all.
  #
  # The recipe is READ FROM `tools/gate.sh`, not retyped here, so this test exercises the
  # shipped flags.
  # Its own temp dir under the system tmp, NOT ExUnit's `@tag :tmp_dir`. That tag roots the
  # directory at `apps/<app>/tmp/`, INSIDE the repository -- so this test would create a git
  # repository inside this one, and `git add -A` stages it as an embedded repo. Measured: it
  # did, on the first run. `on_exit` removes it.
  test "the recipe's output does not depend on ambient rename config" do
    dir =
      Path.join(System.tmp_dir!(), "hacktui-diff-recipe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    recipe = array(File.read!(@gate), "DIFF_RECIPE")

    # THE ENVIRONMENT IS SCRUBBED, and this is not defensive tidiness -- without it this test
    # destroys the caller's commit.
    #
    # `System.cmd/3` inherits the OS environment. Git exports `GIT_INDEX_FILE` to every hook,
    # and under `git commit -a` that is an ABSOLUTE path to the real repository's index lock.
    # `.githooks/pre-commit` runs `./tools/gate.sh test`, so this test runs inside that
    # environment, and `git init` + `git add -A` in the fixture then write the fixture's blobs
    # into the CALLER's index. Measured by review: the suite reported `5 tests, 0 failures`
    # while the outer commit aborted with `error: invalid object ... for 'new.txt'` -- naming a
    # fixture file the contributor has never seen, and never mentioning a test.
    #
    # `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` are silenced for a second reason: the guard below
    # reads `git status`, whose rename detection follows `status.renames`, which defaults to
    # `diff.renames`. Without this the guard fires on exactly the contributor this slice exists
    # to protect -- the one whose global config sets `diff.renames=false` -- and since the test
    # gate is hard-blocking, that contributor could not commit at all. The PIN itself is
    # unaffected; only the guard was ambient-dependent. Also measured by review.
    env = [
      {"GIT_INDEX_FILE", nil},
      {"GIT_DIR", nil},
      {"GIT_WORK_TREE", nil},
      {"GIT_OBJECT_DIRECTORY", nil},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      # `GIT_CONFIG_COUNT`/`_KEY_n`/`_VALUE_n` are read AS IF GIVEN ON THE COMMAND LINE and are
      # untouched by pointing the config files at /dev/null. Round 2 measured that with the pin
      # removed from both copies, setting them turned this test green over an unpinned recipe --
      # the green-that-measured-nothing class. Unsetting the count is sufficient; git reads only
      # the first COUNT pairs.
      {"GIT_CONFIG_COUNT", nil}
    ]

    git = fn args, extra_cfg ->
      # The exit code is checked with a message rather than matched. A bare `{out, 0} =` gives
      # `** (MatchError) no match of right hand side value: {"", 1}` and git's own error never
      # reaches the reader -- which is this slice's subject (a red whose output names nothing)
      # in the test written to close it. Round 2 reached that MatchError via `GIT_COMMON_DIR`.
      case System.cmd("git", extra_cfg ++ args, cd: dir, stderr_to_stdout: true, env: env) do
        {out, 0} ->
          out

        {out, code} ->
          flunk("""
          git #{Enum.join(extra_cfg ++ args, " ")} exited #{code} in the fixture at #{dir}.

          #{out}
          This is the fixture failing, not the recipe. Something in the ambient environment
          reached a `git` this test scrubs for -- check the `env` list above against the
          `GIT_*` variables actually set.
          """)
      end
    end

    # THE FIXTURE'S OWN CONFIG IS HOSTILE, and that is an assertion, not setup.
    #
    # Round 5's three defeats all worked the same way. The environment above is scrubbed of
    # every ambient route to `diff.renames`, and git's BUILT-IN DEFAULT for it is `true` --
    # exactly what the pin forces. So in that environment a pinned recipe and an unpinned one
    # emit identical bytes, and every assertion comparing a shipped consumer to the array is
    # satisfied by a consumer with no pin in it. `derive_diff_hash` unpinned: 5 tests, 0
    # failures. `staged_diff_hash` unpinned: 5 tests, 0 failures. Both at once, leaving
    # `DIFF_RECIPE` with zero consumers and the pin dead code: 5 tests, 0 failures.
    #
    # LOCAL config is the one route the scrub does not close, and cannot: pointing
    # `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` at /dev/null does not touch `.git/config` in
    # the fixture. These two settings make the fixture behave like the contributor this slice
    # exists to protect, so a consumer that drops the pin DIVERGES instead of agreeing, and the
    # detection assertion below fails outright if the ARRAY drops it -- which is the one check
    # that does not compare `tools/gate.sh` against itself.
    #
    # `renameLimit` is pinned for the same reason `renames` is, and round 5 found it the same
    # way: ambient `diff.renameLimit=1` defeats a pinned `diff.renames=true` on the shipped,
    # unmutated recipe -- same tree, two hashes, and the rename-blind one at that. Measured on
    # this fixture: three inexact renames give 3 `rename from` lines pinned, 0 under ambient
    # `diff.renameLimit=1`, and 3 again under `-c diff.renameLimit=0`, which means unlimited
    # and beats the ambient value.
    for args <- [
          ~w(init -q .),
          ~w(config user.email a@b.c),
          ~w(config user.name t),
          ~w(config diff.renames false),
          ~w(config diff.renameLimit 1)
        ],
        do: git.(args, [])

    # THREE inexact renames, not one, and not `git mv` alone. Round 3 defeated two weaker
    # fixtures in succession:
    #
    #   `git mv` with no edit  -- an EXACT rename, which git finds by content hash before the
    #                             rename-limit check and before any similarity threshold. So
    #                             `-c diff.renameLimit=1` and `--find-renames=100%` crippled
    #                             real detection while the assertion below stayed green.
    #   one inexact rename     -- still not enough: a single candidate pair does not exceed a
    #                             rename limit of 1, so `diff.renameLimit=1` remained invisible.
    #
    # A fixture only proves what it can express. Three renamed-and-edited files exceed the
    # limit and fall below a 100% similarity threshold, so both flags now show.
    body = Enum.map_join(1..12, "", &"line#{&1}\n")
    edited = String.replace(body, "line2\n", "line2-CHANGED\n")

    for n <- 1..3, do: File.write!(Path.join(dir, "old#{n}.txt"), body)
    git.(~w(add -A), [])
    git.(~w(commit -qm base), [])

    for n <- 1..3 do
      git.(["mv", "old#{n}.txt", "new#{n}.txt"], [])
      File.write!(Path.join(dir, "new#{n}.txt"), edited)
    end

    git.(~w(add -A), [])

    # THE GUARD MUST BE IMMUNE TO THE CONFIG IT GUARDS AGAINST, and `git status` is not.
    #
    # This guard used `git status --porcelain` with `-c status.renames=true`. Once the fixture
    # set hostile LOCAL config the guard fired on the very fixture it checks -- `5 tests, 1
    # failure`, "the fixture did not produce a rename". Isolated, one hostile setting at a
    # time, three renames staged:
    #
    #   local diff.renames=false     + `-c status.renames=true -c diff.renameLimit=0` -> 3 R
    #   local diff.renameLimit=1     + `-c status.renames=true -c diff.renameLimit=0` -> 0 R
    #
    # So `-c diff.renameLimit=0` overrides a local `diff.renameLimit` for `git diff` -- measured
    # 3 renames under exactly that combination -- and does NOT for `git status`. Rather than
    # depend on that asymmetry, the guard asks the question directly, with both knobs pinned on
    # the command line. The flags are RETYPED here on purpose: this is the one check that must
    # not move when `DIFF_RECIPE` moves, because its job is to prove the fixture is real.
    assert git.(
             ~w(-c diff.renames=true -c diff.renameLimit=0) ++ ~w(diff --cached --name-status),
             []
           ) =~
             ~r/^R/m,
           "the fixture did not produce a rename; this test would then prove nothing"

    # READ FROM `tools/gate.sh` too, not retyped. Round 2 measured why: with the scope
    # retyped, adding `--no-renames` to BOTH shipped copies turned rename detection off --
    # `--no-renames` is a command-line option and beats `-c diff.renames=true` -- and the whole
    # suite stayed green, because the equality test saw the two copies agree and this test's
    # own retyped scope carried no such flag. The recipe was pinned against the property and
    # the scope against a spelling, which is the substitution this file exists to prevent, one
    # level up.
    #
    # Shell single quotes are stripped: `':(exclude)internal/**'` is one quoted word to bash,
    # and `System.cmd` takes the argument, not the quoting.
    scope =
      File.read!(@gate)
      |> array("DIFF_SCOPE")
      |> Enum.map(&String.trim(&1, "'"))

    hash = fn cfg -> :crypto.hash(:sha256, git.(recipe ++ ["diff", "--cached"] ++ scope, cfg)) end

    # TWO PROPERTIES, and round 2 proved one is not enough.
    #
    # Invariance alone says the recipe gives the same bytes whatever ambient config says. It
    # does NOT say those bytes have rename detection in them. Round 2 defeated the earlier
    # version by adding `--no-renames` to DIFF_SCOPE in both shipped copies: a command-line
    # option beats `-c diff.renames=true`, detection went off, and invariance still held --
    # because it holds equally over both invocations. The suite stayed green.
    #
    # Reading DIFF_SCOPE from tools/gate.sh (above) did not fix that on its own, and the proof
    # by effect is what showed it: the flag is then read and passed to BOTH sides, so they
    # still agree. What closes it is asserting the OUTCOME -- the diff must actually contain
    # rename markers.
    raw = git.(recipe ++ ["diff", "--cached"] ++ scope, [])

    assert raw =~ "rename from" and raw =~ "rename to",
           """
           the reviewable-diff recipe does not detect renames at all.

           The fixture contains three renames and the diff of them contains no `rename from` /
           `rename to`. Invariance under ambient config is not enough on its own: a
           command-line option such as `--no-renames` in DIFF_SCOPE turns detection off for
           every invocation equally, so the hashes still agree while the bytes are wrong.

           Recipe and scope as read from tools/gate.sh:
             #{Enum.join(recipe ++ scope, " ")}

           First lines of the diff:
           #{raw |> String.split("\n") |> Enum.take(4) |> Enum.join("\n")}
           """

    # THE COMMAND, not the definition. Everything above reads `DIFF_RECIPE` and `DIFF_SCOPE`
    # and reasons about them; round 3 defeated that by adding `--no-renames` to the `git`
    # invocation INSIDE `staged_diff_hash`, outside both arrays. Every assertion passed. A
    # worse placement broke `tools/gate.sh` outright -- `unknown option` and no hash at all --
    # and the suite still reported five passing tests.
    #
    # So run the shipped script against the fixture and require it to agree with the arrays.
    # `staged_diff_hash` resolves its own toplevel, so with `cd:` set to the fixture it hashes
    # the fixture's index. Any flag added anywhere in that function moves its answer away from
    # `clean` and this fails.
    gate_hash =
      case System.cmd(Path.join(@root, "tools/gate.sh"), ["staged-diff-hash"],
             cd: dir,
             stderr_to_stdout: true,
             env: env ++ [{"LOGDIR", Path.join(dir, ".gatelog")}]
           ) do
        {out, 0} ->
          String.trim(out)

        {out, code} ->
          flunk("`tools/gate.sh staged-diff-hash` exited #{code} in the fixture:\n\n#{out}")
      end

    clean = hash.([])
    hostile = hash.(["-c", "diff.renames=false"])

    # THE NEGATIVE CONTROL: prove this fixture CAN FAIL before trusting that it passed.
    #
    # Everything below compares a shipped consumer against `clean`. That comparison is only
    # evidence if an unpinned recipe would give a DIFFERENT answer here — and for five rounds it
    # would not have, because the scrubbed environment left git on its built-in `diff.renames`
    # default of `true`, which is what the pin forces. The mutation harness proves the gap is
    # real: flipping the fixture's `diff.renames` to `true` leaves every other assertion in this
    # file green (`killed: 36 survivors: 1`, survivor `diff_recipe_fixture_not_hostile`).
    #
    # So: strip the rename pins out of the recipe read from `tools/gate.sh` and require the
    # result to DISAGREE with `clean`. If the fixture's local config stops being hostile, this
    # fails. If the pins leave `DIFF_RECIPE` entirely, `unpinned` equals `clean` and this fails
    # too. It is the assertion that the other assertions are load-bearing.
    unpinned =
      recipe
      |> Enum.chunk_every(2)
      |> Enum.reject(fn
        ["-c", flag] -> String.starts_with?(flag, "diff.rename")
        _ -> false
      end)
      |> List.flatten()

    refute :crypto.hash(:sha256, git.(unpinned ++ ["diff", "--cached"] ++ scope, [])) == clean,
           """
           the fixture cannot tell a pinned recipe from an unpinned one, so every comparison
           below is vacuous.

           Recipe with the rename pins stripped:
             #{Enum.join(unpinned, " ")}

           This means the fixture's own local config is no longer hostile, or the rename pins
           are no longer in DIFF_RECIPE. Round 5 defeated this test three separate ways through
           exactly this hole: with `diff.renames` unset, git's default IS `true`, so a consumer
           with no pin produced byte-identical output and the suite stayed green.
           """

    # THE WHOLE CHAIN, executed. Round 4 found three more defeats, all the same shape as the
    # one round 3 closed: the suite RAN `staged_diff_hash` and only READ everything else.
    #
    #   `derive_diff_hash`  -- the function `Gate - attestation` actually uses. `--no-renames`
    #                          added there left the suite green and reddened the first
    #                          rename-bearing attested commit, silently, which is verbatim the
    #                          failure this slice exists to remove.
    #   commit-msg, earlier -- `export GIT_DIFF_OPTS=-u7` above the `staged=$(` line is outside
    #                          the capture and beats the pinned `-c diff.context=3`.
    #   commit-msg, twice   -- `Regex.run` returns the FIRST match; the LAST assignment to
    #                          `staged` is the one whose value reaches the trailer.
    #
    # So run the real hook and the real gate over the fixture and require the chain to agree.
    #
    # ROUND 5 DEFEATED THAT AGREEMENT, and the correction is the fixture's hostile local config
    # above, not this comment. Agreement between a pinned array and a consumer proves nothing
    # when the environment cannot express disagreement: with `diff.renames` unset, git's
    # built-in default IS `true`, so a consumer that dropped the pin emitted byte-identical
    # output and every assertion here passed. Round 5 removed the pin from `derive_diff_hash`,
    # from `staged_diff_hash`, and from both at once via `unset 'DIFF_RECIPE[8]'` -- 5 tests, 0
    # failures each time, while a contributor with `diff.renames=false` got a red attestation.
    # Running the artefact detects an INVERTED pin and is blind to an ABSENT one, unless the
    # fixture is hostile. It now is.
    msg = Path.join(dir, "msg.txt")
    # The slice name is real: `.githooks/commit-msg` refuses a subject whose slice directory
    # does not exist, which is the hook doing its job and worth not defeating with a fake one.
    File.write!(msg, "16l-diff-renames-pin: fixture rename\n")

    # The hook resolves the slice directory relative to ITS CWD, which here is the fixture,
    # so the fixture needs one. `internal/` is gitignored in the real tree and untracked here,
    # so this affects nothing the recipe hashes.
    File.mkdir_p!(Path.join(dir, "internal/slices/16l-diff-renames-pin"))

    case System.cmd(Path.join(@root, ".githooks/commit-msg"), [msg],
           cd: dir,
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} -> :ok
      {out, code} -> flunk("`.githooks/commit-msg` exited #{code} in the fixture:\n\n#{out}")
    end

    trailer =
      case Regex.run(~r/^Reviewed-diff:\s*sha256:([0-9a-f]{64})/m, File.read!(msg),
             capture: :all_but_first
           ) do
        [h] -> h
        _ -> flunk("`.githooks/commit-msg` wrote no Reviewed-diff trailer:\n#{File.read!(msg)}")
      end

    assert trailer == Base.encode16(clean, case: :lower),
           """
           the trailer `.githooks/commit-msg` writes does not agree with DIFF_RECIPE + DIFF_SCOPE.

             commit-msg wrote : #{trailer}
             arrays say       : #{Base.encode16(clean, case: :lower)}

           Something in that hook is outside the invocation this test compares against
           `tools/gate.sh` -- an environment assignment earlier in the file, a second
           assignment to `staged` whose value is the one that survives, a `cd`. Reading the
           one invocation cannot see any of those, which is why this runs the hook.
           """

    git.(["-c", "core.hooksPath=/dev/null", "commit", "-q", "-F", msg], [])

    case System.cmd(Path.join(@root, "tools/gate.sh"), ["attestation", "HEAD~1..HEAD"],
           cd: dir,
           stderr_to_stdout: true,
           env: env ++ [{"LOGDIR", Path.join(dir, ".gatelog2")}]
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        flunk("""
        `tools/gate.sh attestation` rejected a commit whose trailer the shipped hook wrote,
        over a rename-bearing diff. Exit #{code}:

        #{out}
        `derive_diff_hash` -- which is what the attestation gate uses, and which no other
        assertion here executes -- disagrees with the hook. On a rename-free diff this stays
        green, so it would surface first on a rename-bearing attested commit, with nothing in
        the output naming the cause.
        """)
    end

    assert gate_hash == Base.encode16(clean, case: :lower),
           """
           `tools/gate.sh staged-diff-hash` does not agree with DIFF_RECIPE + DIFF_SCOPE.

             gate.sh says : #{gate_hash}
             arrays say   : #{Base.encode16(clean, case: :lower)}

           The two are supposed to be the same command. They differ, so something in
           `staged_diff_hash` is not in the arrays this test reads -- a flag added to the `git`
           line inside the function, a `cd`, an environment assignment. Reading the arrays
           cannot see any of those, which is why this assertion runs the script.
           """

    assert clean == hostile,
           """
           the reviewable-diff recipe still depends on ambient `diff.renames`.

           With rename detection on, git emits `similarity index` / `rename from` / `rename to`;
           with it off, a delete-plus-add pair. Same tree, different bytes, different sha256 --
           so a contributor whose config differs from CI's writes one hash into the
           `Reviewed-diff` trailer while `Gate - attestation` derives another, and the gate goes
           red with nothing in its output naming a config knob.

           Recipe as read from tools/gate.sh:
             #{Enum.join(recipe, " ")}
           """
  end
end
