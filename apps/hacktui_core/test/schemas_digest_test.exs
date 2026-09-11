defmodule HacktuiCore.SchemasDigestTest do
  use ExUnit.Case, async: true

  # Digest drift between this repo and the other repository that pins a contract is the failure this guards against: two
  # repos pin one contract, and a schema edited on one side without a new digest on both is a
  # silent fork. It runs in the ordinary suite, which is hard-blocking.
  #
  # THE AUTHORITATIVE LEDGER IS `schemas/ledger.tsv`. It is read by this file and by nothing
  # else. `schemas/README.md` is derived output.
  #
  # GFM's grammar is wider than any predicate written against it (a lost backtick, a second
  # table, optional leading pipes all parse as tables). So the ledger is not Markdown: the
  # parser defines the grammar -- one anchored regex -- and a line either matches it exactly
  # or the file is broken.
  #
  # What is enforced is enforced by the tests in this file. No list of names is kept here;
  # lists go stale and a comment cannot check itself.
  @root Path.expand("../../..", __DIR__)
  @schemas_dir Path.join(@root, "schemas")
  @ledger Path.join(@schemas_dir, "ledger.tsv")
  @readme Path.join(@schemas_dir, "README.md")

  # file \t schema_const \t revision \t ordinal \t digest
  @row ~r/\A(?<file>[A-Za-z0-9][A-Za-z0-9._-]*\.json)\t(?<const>[a-z0-9][a-z0-9._\/-]*)\t(?<rev>baseline|\d{4}-\d{2}-\d{2})\t(?<ord>[1-9]\d*)\t(?<digest>[0-9a-f]{64})\z/

  @digest_re ~r/[0-9a-f]{64}/i

  @begin_marker "<!-- BEGIN GENERATED LEDGER -->"
  @end_marker "<!-- END GENERATED LEDGER -->"

  defp ledger_lines do
    @ledger |> File.read!() |> String.split("\n") |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def __parse_line__(line) do
    case Regex.named_captures(@row, line) do
      nil ->
        {:error, line}

      c ->
        {:ok,
         %{
           file: c["file"],
           const: c["const"],
           # "baseline" precedes every date, so it sorts to "" rather than lexicographically
           # after a four-digit year. The label is kept separately for rendering.
           rev: {if(c["rev"] == "baseline", do: "", else: c["rev"]), String.to_integer(c["ord"])},
           rev_label: c["rev"],
           digest: c["digest"]
         }}
    end
  end

  defp parsed, do: Enum.map(ledger_lines(), &__parse_line__/1)
  defp rows, do: for({:ok, r} <- parsed(), do: r)
  # Last row wins: Map.new/2 keeps the final value for a repeated key, and the ledger is in
  # revision order (asserted below), so the in-force pin is the last row for each file.
  defp pinned_digests, do: Map.new(rows(), &{&1.file, &1.digest})

  # Derived output. README's generated block is byte-compared against this.
  @doc false
  def __render__(rows) do
    header = ["| File | Schema const | Revision | sha256 |", "|---|---|---|---|"]

    body =
      Enum.map(rows, fn r ->
        {_sort, ord} = r.rev
        label = if ord == 1, do: r.rev_label, else: "#{r.rev_label} (#{ord})"
        "| `#{r.file}` | `#{r.const}` | #{label} | `#{r.digest}` |"
      end)

    Enum.join(header ++ body, "\n")
  end

  defp schema_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(&(&1 in ["README.md", "ledger.tsv"]))
    |> Enum.sort()
  end

  # The digest check over an arbitrary directory and pin map, so a control can drive it with a
  # fixture. The real test passes @schemas_dir; a pinned file need not be present in this
  # repository (a row is a claim about a digest, checkable wherever the bytes are), so the
  # control is what guarantees the comparison is exercised even when the set is empty.
  defp digest_check(dir, pins) do
    for file <- schema_files(dir) do
      cond do
        not Map.has_key?(pins, file) -> {:no_row, file}
        sha256(Path.join(dir, file)) != pins[file] -> {:drift, file}
        true -> {:ok, file}
      end
    end
  end

  defp sha256(path) do
    :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
  end

  test "every line of schemas/ledger.tsv matches the row grammar exactly" do
    malformed = for {:error, line} <- parsed(), do: line

    assert malformed == [],
           "schemas/ledger.tsv has lines that are not rows:\n" <>
             Enum.map_join(malformed, "\n", &("  " <> inspect(&1))) <>
             "\nA line is a row or the file is broken. There is no third outcome and nothing " <>
             "is skipped."
  end

  test "every schema file present under schemas/ carries a pinned digest, and it matches" do
    pins = pinned_digests()
    refute pins == %{}, "no pinned rows parsed from schemas/ledger.tsv"

    for result <- digest_check(@schemas_dir, pins) do
      assert match?({:ok, _}, result),
             "schemas/ digest check failed: #{inspect(result)}\n" <>
               ":no_row means a file under schemas/ has no row in ledger.tsv; :drift means its " <>
               "bytes do not match the pinned digest. A schema change is a new digest in BOTH repos."
    end
  end

  test "the ledger is append-only in order, and no digest is reused" do
    all = rows()
    refute all == [], "no rows parsed from schemas/ledger.tsv"

    for {file, file_rows} <- Enum.group_by(all, & &1.file) do
      keys = Enum.map(file_rows, & &1.rev)

      assert keys == Enum.sort(keys),
             "rows for #{file} are not in revision order: #{inspect(keys)}"

      digests = Enum.map(file_rows, & &1.digest)
      dupes = digests -- Enum.uniq(digests)

      assert dupes == [],
             "schemas/ledger.tsv reuses a digest for #{file}: #{inspect(Enum.uniq(dupes))}. " <>
               "A revert is a real decision -- record it as a distinct row."
    end
  end

  @recorded_history [
    "db89314ab5fc4c6b3d8b1bcb2dce2dc36c5167e4ebd37e144c978530f09ed604"
  ]

  test "the hold socket ledger retains every recorded revision, in order" do
    file = "sanction.hold-v1.schema.json"
    actual = for r <- rows(), r.file == file, do: r.digest

    assert Enum.take(actual, length(@recorded_history)) == @recorded_history,
           "schemas/ledger.tsv no longer carries the recorded revision history for #{file}. " <>
             "Rows are appended, never replaced or removed."
  end

  test "the hold socket row pins the revision both repos pin" do
    file = "sanction.hold-v1.schema.json"

    assert Map.get(pinned_digests(), file) ==
             "db89314ab5fc4c6b3d8b1bcb2dce2dc36c5167e4ebd37e144c978530f09ed604"
  end

  # --- README is derived output -------------------------------------------------------------

  defp generated_block(body) do
    [_, block] = String.split(body, @begin_marker, parts: 2)
    [block, _] = String.split(block, @end_marker, parts: 2)
    String.trim(block)
  end

  test "README's generated block is byte-identical to render(ledger.tsv)" do
    assert generated_block(File.read!(@readme)) == __render__(rows()),
           "schemas/README.md's generated block is stale. It is DERIVED OUTPUT: regenerate it " <>
             "from schemas/ledger.tsv rather than editing it."
  end

  # See the README controls in this file.
  test "no 64-hex digest appears in README.md outside the generated block" do
    stray = stray_digests(File.read!(@readme))

    assert stray == [],
           "a 64-hex digest appears in schemas/README.md outside the generated block: " <>
             "#{inspect(stray)}. README is derived output and pins nothing; a digest outside " <>
             "the generated block is the only way it could appear to."
  end

  # Digests appearing outside the generated block, over an arbitrary body so a control can
  # append to a fixture rather than to the real file.
  defp stray_digests(body) do
    [before_block, rest] = String.split(body, @begin_marker, parts: 2)
    [_, after_block] = String.split(rest, @end_marker, parts: 2)
    Regex.scan(@digest_re, before_block <> after_block) |> List.flatten()
  end

  # --- permanent controls -------------------------------------------------------------------
  #
  # Two Markdown shapes that once parsed as pins now assert the OPPOSITE property.

  @evil "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888"

  test "control: an optional-pipe table appended to README changes nothing enforced" do
    pins_before = pinned_digests()

    pipeless = """
    File | Schema const | Revision | sha256
    --- | --- | --- | ---
    `sanction.hold-v1.schema.json` | `sanction.hold/v1` | 2026-09-05 | `#{@evil}`
    """

    # Actually appended -- to a body, never to the real file.
    tampered = File.read!(@readme) <> "\n" <> pipeless

    # Nothing enforced moves: pins are parsed from ledger.tsv, and the generated block is
    # delimited by markers the append lands after.
    assert pinned_digests() == pins_before
    assert generated_block(tampered) == generated_block(File.read!(@readme))
    refute String.contains?(__render__(rows()), @evil)
    refute @evil in Map.values(pins_before)

    # And the tamper is not invisible: it is caught as a stray digest outside the block.
    assert @evil in stray_digests(tampered)
    refute @evil in stray_digests(File.read!(@readme))
  end

  test "control: a second GFM table appended to README changes nothing enforced" do
    pins_before = pinned_digests()

    second = """
    | File | Schema const | Revision | sha256 |
    |---|---|---|---|
    | `sanction.hold-v1.schema.json` | `sanction.hold/v1` | 2026-09-05 | `#{@evil}` |
    """

    tampered = File.read!(@readme) <> "\n" <> second

    assert pinned_digests() == pins_before
    assert generated_block(tampered) == generated_block(File.read!(@readme))
    refute @evil in Map.values(pins_before)

    assert @evil in stray_digests(tampered)
    refute @evil in stray_digests(File.read!(@readme))
  end

  test "control: either reproduction appended to ledger.tsv is MALFORMED" do
    pipeless_row =
      "`sanction.hold-v1.schema.json` | `sanction.hold/v1` | 2026-09-05 | `#{@evil}`"

    gfm_row =
      "| `sanction.hold-v1.schema.json` | `sanction.hold/v1` | 2026-09-05 | `#{@evil}` |"

    assert {:error, ^pipeless_row} = __parse_line__(pipeless_row)
    assert {:error, ^gfm_row} = __parse_line__(gfm_row)
  end

  # Last row wins, not first and not "any row": a superseded digest must not remain in force.
  test "control: the in-force pin is the last row for a file, not the first" do
    file = "zz.schema.json"

    lines = [
      "#{file}\tzz/v1\tbaseline\t1\t#{String.duplicate("a", 64)}",
      "#{file}\tzz/v1\t2026-09-02\t1\t#{String.duplicate("b", 64)}"
    ]

    rows = for {:ok, r} <- Enum.map(lines, &__parse_line__/1), do: r

    assert Map.new(rows, &{&1.file, &1.digest})[file] == String.duplicate("b", 64),
           "the last row for a file is its pin; a superseded row must not stay in force"
  end

  test "control: an uppercase or mixed-case digest outside the block is caught" do
    lower = String.duplicate("a", 40) <> String.duplicate("b", 24)
    upper = String.upcase(lower)
    mixed = String.upcase(String.slice(lower, 0..31)) <> String.slice(lower, 32..63)

    for d <- [lower, upper, mixed] do
      assert Regex.match?(@digest_re, "see #{d} here"),
             "the README guard must not depend on the case the renderer happens to emit"
    end
  end

  # A harness that compares the target to the CALLER'S repository answers "is this where I am
  # standing" rather than "is this a copy", and would stage into an unrelated clone. Permanent,
  # because a probe harness that can touch the real tree is the hazard probes-on-a-copy exists for.
  test "control: the probe harness refuses the canonical repository" do
    harness = Path.join(@root, "tools/probe.sh")
    assert File.exists?(harness)

    # The CANONICAL repository, derived the way the harness derives it. @root is the tree this
    # test is running in, which inside a probe worktree is NOT canonical -- pointing the harness
    # at that made it accept and run the whole suite recursively, which is how this control
    # first failed.
    {common, 0} =
      System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: @root)

    canonical = common |> String.trim() |> Path.dirname()

    {out, code} =
      System.cmd("bash", [harness, canonical, "/dev/null", "refusal-control", "true"],
        stderr_to_stdout: true,
        cd: @root
      )

    assert code != 0, "the harness must refuse the canonical repository, got exit #{code}"
    assert out =~ "REFUSING"
  end

  test "control: malformed ledger lines are rejected, not skipped" do
    good =
      "sanction.hold-v1.schema.json\tsanction.hold/v1\tbaseline\t1\t" <>
        String.duplicate("a", 64)

    assert {:ok, %{digest: _}} = __parse_line__(good)

    for bad <- [
          good <> "\tsixth-column",
          String.replace(good, String.duplicate("a", 64), String.duplicate("a", 65)),
          String.replace(good, String.duplicate("a", 64), String.duplicate("a", 63)),
          String.replace(good, String.duplicate("a", 64), String.duplicate("A", 64)),
          String.replace(good, "\tbaseline\t", "\t2026-9-2\t"),
          String.replace(good, "\t1\t", "\t0\t"),
          good <> "\textra",
          " " <> good,
          good <> " "
        ] do
      assert {:error, ^bad} = __parse_line__(bad), "must reject: #{inspect(bad)}"
    end
  end

  # Binds digest_check/2 and sha256/1. The real schemas/ set may be empty (a pin need not have
  # its file here), so without this fixture the comparison could never execute and could not
  # go red. This control stays regardless of what schemas/ holds.
  test "control: digest_check is green on a match, red on drift, red on a missing row" do
    dir = Path.join(System.tmp_dir!(), "uv-digest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "scratch.schema.json")
    File.write!(path, ~s({"$id":"scratch"}\n))
    good = sha256(path)

    assert [{:ok, "scratch.schema.json"}] == digest_check(dir, %{"scratch.schema.json" => good})

    assert [{:drift, "scratch.schema.json"}] ==
             digest_check(dir, %{"scratch.schema.json" => String.duplicate("0", 64)})

    assert [{:no_row, "scratch.schema.json"}] == digest_check(dir, %{})
  end
end
