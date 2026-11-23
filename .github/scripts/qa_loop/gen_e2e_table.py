#!/usr/bin/env python3
"""Regenerate the e2e expectation table -- the table `checks.py` asserts with.

WHY THIS EXISTS
===============
`checks.py`'s `_EXAMPLES` table is, by its own comment, GENERATED and not
typed: each row is (example name, a prefix of the example's templatised final
stdout line, that line's exact length, the example's minimum non-empty stdout
line count).  The comment names "the e2e table generator" and a `--check` mode
that "re-runs it and diffs against this file" -- and there was no such
generator in the tree.

That is not a tidiness complaint.  The table went STALE, and the way it went
stale is the whole reason this file exists:

  * round 87 moved the toolchain to moon 0.1.20261117, whose core renders a
    `Byte` as the NUMBER (`69`) where the earlier core rendered `b'\\x45'`;
  * `examples/bitexact/main.mbt` was adapted to print numbers instead of
    Python bytes literals -- and said why, in its own comment;
  * the TABLE WAS NOT REGENERATED.  It still expected the `b'\\x<n>'` form.

So the e2e gate went RED on `master` -- the table asserted a final line the
example had not printed since round 87 -- and the release could not be cut.
The gate is right and the table was wrong; the table is what had to move.

WHAT THIS DOES
==============
  --check    re-run every example and DIFF the measured rows against the
             table in `checks.py`.  Exit non-zero when they differ.  This is
             what a maintainer runs before trusting the table.
  --write    replace the `_EXAMPLES` block in `checks.py` with the measured
             rows, byte for byte, leaving every other byte of the file alone.
  (neither)  print the measured table.

BOTH SIDES GO THROUGH THE SAME FUNCTION
=======================================
The prefix, the length and the line count are computed with the harness's OWN
`checks._templatise` and `checks._e2e_lines`, and the rows are compared with
the harness's own `_e2e_verdict`.  A generator that templatises differently
from the check would produce a table the check rejects -- and the table is
the thing that has to be TRUE.

The prefix is the first 60 characters of the templatised final line: a prefix
alone passes a line that got cut in half, which is why the row also carries
the line's exact length.

Usage:
    python .github/scripts/qa_loop/gen_e2e_table.py [--check|--write]
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import checks as C  # noqa: E402

PREFIX_CHARS = 60


def measure():
    """The measured table: one row per example, in the harness's own terms."""
    rows = []
    for name, _prefix, _want_len, _min_lines in C._EXAMPLES:
        d = os.path.join("examples", name)
        if not os.path.isdir(os.path.join(C.ROOT, d)):
            rows.append((name, None, None, None, "the example directory is missing"))
            continue
        rc, out, err = C.run_split(["moon", "run", "--target", "native", d], timeout=900)
        if rc != 0:
            rows.append((name, None, None, None,
                         "exit=%d%s" % (rc, (": " + err.strip()[:120]) if err.strip() else "")))
            continue
        lines = C._e2e_lines(out)
        if not lines:
            rows.append((name, None, None, None, "the example printed no line"))
            continue
        got = C._templatise(lines[-1])
        rows.append((name, got[:PREFIX_CHARS], len(got), len(lines), None))
    return rows


def dquote(s):
    """A double-quoted Python literal for a string.

    The table in `checks.py` is written with DOUBLE quotes, and a generator
    that emits `repr()` would re-quote every row that has no apostrophe in
    it -- twenty rows of churn for no change of meaning.  The style is part
    of the file, so the generator keeps it.
    """
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def render(rows):
    """The table, in the format `checks.py` holds it."""
    out = ["_EXAMPLES = ["]
    for name, prefix, want_len, min_lines, why in rows:
        if why:
            raise SystemExit("!! %s: %s -- the table cannot be regenerated from a "
                             "broken example" % (name, why))
        out.append("    (%s, %s, %d, %d)," % (dquote(name), dquote(prefix),
                                              want_len, min_lines))
    out.append("]")
    return "\n".join(out) + "\n"


def diff(measured, current):
    """The rows that differ: (name, field, stored, measured).

    Field-wise, because the three columns are three different CLAIMS:

      * the prefix and the length are asserted EXACTLY by the check, so a
        difference in either means the table asserts a line the example does
        not print -- that is the staleness this file exists to catch;
      * the line count is a FLOOR (the check asserts `lines >= min_lines`),
        so a stored floor below the measured count is satisfied, not stale,
        and only a stored floor ABOVE the measured count would fail the
        check.
    """
    cur = {r[0]: r for r in current}
    bad = []
    for name, prefix, want_len, min_lines, why in measured:
        if why:
            bad.append((name, "measured", "<not measured>", "%s" % why))
            continue
        c = cur.get(name)
        if c is None:
            bad.append((name, "row", "<no row>",
                        "prefix=%r len=%d lines=%d" % (prefix, want_len, min_lines)))
            continue
        if c[1] != prefix:
            bad.append((name, "prefix", repr(c[1]), repr(prefix)))
        if c[2] != want_len:
            bad.append((name, "length", "%d" % c[2], "%d" % want_len))
        if c[3] > min_lines:
            bad.append((name, "min lines", "%d" % c[3], "%d" % min_lines))
    for name in sorted(cur):
        if not any(m[0] == name for m in measured):
            bad.append((name, "row", "prefix=%r len=%d lines=%d"
                        % (cur[name][1], cur[name][2], cur[name][3]),
                        "<the example was not measured>"))
    return bad


def main(argv):
    mode = "--check" if "--check" in argv else ("--write" if "--write" in argv else "")
    rows = measure()
    print("measured %d example(s)" % len(rows))
    for name, prefix, want_len, min_lines, why in rows:
        if why:
            print("  %-18s FAILED: %s" % (name, why))
        else:
            print("  %-18s prefix=%-62r len=%-4d lines=%d" % (name, prefix, want_len, min_lines))

    if mode == "--check":
        bad = diff(rows, C._EXAMPLES)
        print()
        if not bad:
            print("the table in checks.py MATCHES the tree")
            return 0
        print("the table in checks.py is STALE -- %d field(s) differ:" % len(bad))
        for name, field, was, now in bad:
            print("  %-18s %-10s stored: %-40s measured: %s"
                  % (name, field, was, now))
        return 1

    table = render(rows)

    if mode == "--write":
        path = os.path.join(C.ROOT, ".github", "scripts", "qa_loop", "checks.py")
        raw = io.open(path, "rb").read()
        text = raw.decode("utf-8")
        i = text.index("_EXAMPLES = [")
        j = text.index("\n]\n", i) + len("\n]\n")
        out = text[:i] + table + text[j:]
        io.open(path, "wb").write(out.encode("utf-8"))
        print()
        print("rewrote the _EXAMPLES block in %s" % path)
        print("  %d -> %d bytes; every other byte is unchanged: %s"
              % (len(raw), len(out.encode("utf-8")), text[:i] == out[:i] and out.endswith(text[j:])))
        return 0

    print()
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
