# Schemas

Contract schemas pinned by digest. **`ledger.tsv` in this directory is authoritative**; the
table below is generated from it and compared byte-for-byte by
`apps/hacktui_core/test/schemas_digest_test.exs`, which runs in the ordinary, hard-blocking
suite. Regenerate the table from `ledger.tsv`; never edit it by hand.

## Ledger format

One row per pinned revision, five tab-separated fields, no header, no blank lines:

```
<file>  <schema const>  <revision>  <ordinal>  <sha256>
```

- `file` — the schema's filename (`*.json`).
- `schema const` — the `schema` value a request carries (for example `sanction.hold/v1`),
  not the file's `$id`. Two distinct identifiers.
- `revision` — `baseline`, or the `YYYY-MM-DD` label the file carries in its own `$comment`.
  A convention: no test compares the label to the file's `$comment`.
- `ordinal` — 1, 2, … for several revisions on one date.
- `sha256` — lowercase hex of the whole file: `sha256sum <file>`.

The row grammar is one anchored regular expression in the test. A line matches it exactly
or the file is broken; nothing is skipped.

**Append-only, last row wins.** Rows are appended, never replaced or removed. The last row for
a file is the pin in force; earlier rows are the revisions it superseded, so either repository
can be checked from the other. Rows for a file must be in revision order, and a digest is
never reused — a revert is a new row.

**A row is a claim about a digest, not about where the bytes are.** A pinned file need not
be present in this directory; the digest is checkable against the bytes wherever they are
held. A file that *is* present must match its in-force row exactly.

## How the test fails

- a line that does not match the row grammar → the ledger is malformed;
- a file under `schemas/` with no row → `:no_row`;
- a file whose bytes do not hash to its in-force row → `:drift`;
- rows for a file out of revision order, or a reused digest → append-only violated;
- the generated table below differing by one byte from a render of the ledger → stale README;
- any 64-hex digest appearing in this file outside the generated block → a pin outside the
  ledger.

**Diff schema revisions structurally with `jq -S`, not textually.** Revisions reformat as
well as change content, so a textual diff overstates what moved.

<!-- BEGIN GENERATED LEDGER -->

| File | Schema const | Revision | sha256 |
|---|---|---|---|
| `sanction.hold-v1.schema.json` | `sanction.hold/v1` | baseline | `db89314ab5fc4c6b3d8b1bcb2dce2dc36c5167e4ebd37e144c978530f09ed604` |

<!-- END GENERATED LEDGER -->

A schema change is a new digest in both repositories that pin it, in one change.
