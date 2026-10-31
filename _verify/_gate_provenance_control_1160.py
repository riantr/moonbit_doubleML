"""Positive control: does _gate_provenance_1160.py actually FAIL when the
README is wrong -- and for the RIGHT REASON?

A gate that passes on a correct file and also passes on a broken one is
worthless.  A gate that fails on a broken file for an UNRELATED reason is
only a little better: it would report DETECTED for a mutation it never
actually looked at.  So every mutation here states the marker the gate's
output must carry, and a mutation that makes the gate exit non-zero with
the WRONG marker is reported as a MISS, not as a detection.

THE MUTATIONS, AND WHY THERE ARE ELEVEN
=======================================
The gate has four ways to fail, and each one needs a mutation that reaches
it:

  table comparison   the marker cell of one row is wrong -- three
                     directions, because the truth model has three values:
                     a name-identical class, a renamed one, and the one
                     with no 1:1 counterpart;
  flat assertions    the prose still asserts a flat "all 22 are upstream";
  row-count guard    a row is deleted from the table, so the parser cannot
                     account for every estimator;
  header guard       the table's own header is gone, so the parser cannot
                     find the table at all;
  derived exception  the PORT renames its `DoubleMLDIDCrossSection`, so
                     upstream's `DoubleMLDIDCS` has no counterpart after
                     all -- which proves the one documented exception is
                     DERIVED from the port's source and not asserted as a
                     literal.

WHY THE FIRST TWO MUTATIONS USED TO BE ENOUGH, AND ARE NOT ANY MORE
====================================================================
The first version of this control appended a whole extra ROW at the end of
the README.  That worked against the old gate, which parsed the WHOLE
document and kept the LAST row it saw for each name -- and it stopped
working the moment the gate was repaired to read the ESTIMATOR TABLE only,
because an appended row is not in the table.

The control therefore failed after the repair, and it failed the way a
check must: it reported MISSED for both table mutations and said "GATE
DOES NOT DISCRIMINATE".  The fix is the point of this rewrite -- a table
mutation has to land INSIDE the table, on the row it claims to break, and
has to be found by the header the gate itself uses.

Nothing on disk is modified: the copy lives in a temp dir and is deleted.
The sdist is a vendored, deliberately untracked artefact, so when it is
absent the control SKIPS -- loudly -- instead of failing over a file that
was never there.
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")
DOC = os.path.join(ROOT, "doc", "004_estimators", "readme.mbt.md")
GATE = os.path.join(ROOT, "_verify", "_gate_provenance_1160.py")
PKG = os.path.join(ROOT, "moonbit_doubleML")

SDIST = os.path.join(ROOT, "doubleml-0.11.4.tar.gz")
if not os.path.isfile(SDIST):
    SDIST = os.path.join(ROOT, "_verify", "doubleml-0.11.4.tar.gz")

if not os.path.isfile(SDIST):
    print("SKIP: the 0.11.4 sdist is not present at %s -- the provenance "
          "gate cannot be exercised here." % SDIST)
    sys.exit(0)


# ---------------------------------------------------------------- the helpers
def table_span(text):
    """The estimator table's own span: its header, and its end.

    The gate finds the table by this header, so the control must find it the
    same way -- a control that located the table by a different rule would
    be testing a table the gate never reads.
    """
    start = text.find("| Model |")
    if start < 0:
        raise SystemExit("!! the estimator table's header was not found")
    end = text.find("\n\n", start)
    if end < 0:
        raise SystemExit("!! the estimator table's end was not found")
    return start, end


def mutate_row(text, name, old, new):
    """Replace `old` with `new` on the row that starts with `name`.

    Scoped to the TABLE: the README has two more tables whose rows also
    begin with a `DoubleML*` name, and a mutation that landed in one of
    those would be testing the wrong region.
    """
    start, end = table_span(text)
    region = text[start:end]
    lines = region.split("\n")
    hit = [i for i, l in enumerate(lines)
           if l.startswith("| `%s` |" % name)]
    if len(hit) != 1:
        raise SystemExit("!! the row for %s was found %d times in the table "
                         "(expected 1)" % (name, len(hit)))
    i = hit[0]
    if lines[i].count(old) != 1:
        raise SystemExit("!! the row for %s carries %r %d times (expected 1)"
                         % (name, old, lines[i].count(old)))
    lines[i] = lines[i].replace(old, new, 1)
    return text[:start] + "\n".join(lines) + text[end:]


def delete_row(text, name):
    start, end = table_span(text)
    region = text[start:end]
    lines = [l for l in region.split("\n")
             if not l.startswith("| `%s` |" % name)]
    if len(lines) == len(region.split("\n")):
        raise SystemExit("!! the row for %s was not found in the table" % name)
    return text[:start] + "\n".join(lines) + text[end:]


def drop_header(text):
    """Remove EVERY header line that carries the table's own marker.

    The README has two headers containing "| Model |": the estimator table's
    and the comparison table's (`| Driver | Model | DGP | True theta |`).  The
    gate finds the table with `find("| Model |")`, so removing only the
    estimator table's header does not remove the MARKER -- the gate would
    find the other table instead, parse zero rows from it and abort on the
    row count, which is a different guard and a different reason to fail.
    """
    lines = text.split("\n")
    keep = [l for l in lines if "| Model |" not in l]
    if len(keep) == len(lines):
        raise SystemExit("!! no header line carrying '| Model |' was found")
    return "\n".join(keep)


def rename_struct(pkg_dir, old, new):
    """Rename a struct in the PORT's sources, so the port no longer HAS it."""
    hits = 0
    for base, dirs, files in os.walk(pkg_dir):
        dirs[:] = [d for d in dirs if d not in ("_build", "_verify", "target", ".git")]
        for fn in files:
            if not fn.endswith(".mbt"):
                continue
            p = os.path.join(base, fn)
            with io.open(p, encoding="utf-8", newline="") as fh:
                src = fh.read()
            if "struct " + old not in src:
                continue
            with io.open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write(src.replace("struct " + old, "struct " + new))
            hits += 1
    if hits == 0:
        raise SystemExit("!! no source declares `struct %s`" % old)
    return hits


# ------------------------------------------------------------------ the setup
tmp = tempfile.mkdtemp(prefix="prov_gate_")
shutil.copytree(PKG, os.path.join(tmp, "moonbit_doubleML"),
                ignore=shutil.ignore_patterns("_build", "_verify", "target", ".git"))
shutil.copytree(os.path.join(ROOT, "doc"), os.path.join(tmp, "doc"))
shutil.copy2(SDIST, os.path.join(tmp, "doubleml-0.11.4.tar.gz"))
bad_readme = os.path.join(tmp, "README.mbt.md")
bad_doc = os.path.join(tmp, "doc", "004_estimators", "readme.mbt.md")
gate_copy = os.path.join(tmp, "gate.py")
shutil.copy2(GATE, gate_copy)   # the gate locates its inputs relative to its own path

original = io.open(README, encoding="utf-8", newline="").read()
original_doc = io.open(DOC, encoding="utf-8", newline="").read()

# (label, expect-marker, what the mutation does)
MUTATIONS = [
    # --- the table comparison, in all three directions ------------------------
    ("A: a name-identical class claims no counterpart",
     "MISMATCH",
     lambda t, d: (mutate_row(t, "DoubleMLPLR", "*(upstream)*",
                               "*(no upstream counterpart)*"), d)),

    ("B: the class with no 1:1 counterpart claims plain upstream",
     "MISMATCH",
     lambda t, d: (mutate_row(t, "DoubleMLDIDCrossSection",
                               "*(upstream, renamed)*", "*(upstream)*"), d)),

    ("C: a renamed class claims plain upstream",
     "MISMATCH",
     lambda t, d: (mutate_row(t, "DoubleMLRDD", "*(upstream, renamed)*",
                               "*(upstream)*"), d)),

    # --- the flat prose assertions -------------------------------------------
    ("D: README 'Every one of the 22 has a counterpart'",
     "OVERSTATED PROVENANCE ASSERTION",
     lambda t, d: (t + "\nEvery one of the 22 has a counterpart in "
                   "doubleml 0.11.4.\n", d)),

    ("E: README 'all 22 models in upstream'",
     "OVERSTATED PROVENANCE ASSERTION",
     lambda t, d: (t + "\ncovering all 22 models in upstream.\n", d)),

    ("F: README 'no textual occurrence anywhere in the sdist'",
     "OVERSTATED PROVENANCE ASSERTION",
     lambda t, d: (t + "\nand no textual occurrence anywhere in the sdist.\n", d)),

    ("G: doc 'All 22 have an upstream counterpart'",
     "OVERSTATED PROVENANCE ASSERTION",
     lambda t, d: (t, d + "\nAll 22 have an upstream doubleml.DoubleML* "
                   "counterpart.\n")),

    ("H: README '19 upstream models'",
     "OVERSTATED PROVENANCE ASSERTION",
     lambda t, d: (t + "\nAll 19 upstream models are faithfully "
                   "re-implemented.\n", d)),

    # --- the guards the repair added -----------------------------------------
    ("I: a row is deleted from the estimator table",
     "estimator rows parsed",
     lambda t, d: (delete_row(t, "DoubleMLPolicyTree"), d)),

    ("J: the estimator table's own header is gone",
     "header was not found",
     lambda t, d: (drop_header(t), d)),

    # --- the exception is DERIVED, not asserted -------------------------------
    ("K: the port renames its DoubleMLDIDCrossSection, so upstream's "
     "DoubleMLDIDCS has no counterpart",
     "MISMATCH",
     None),   # handled specially: it changes the PORT, not the document
]


def run_gate(path=None):
    p = subprocess.run([sys.executable, path or gate_copy],
                       capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


ok = True
missed = []
harness = []
try:
    # The copy itself must be faithful: an unmutated copy has to PASS, or a
    # mutation that "fails" proves nothing.
    io.open(bad_readme, "w", encoding="utf-8", newline="").write(original)
    io.open(bad_doc, "w", encoding="utf-8", newline="").write(original_doc)
    rc0, out0 = run_gate()
    print("  %-8s  the unmutated COPY passes (exit=%d)" %
          ("PASS" if rc0 == 0 else "BROKEN", rc0))
    if rc0 != 0:
        ok = False
        harness.append("the unmutated copy does not pass")
        print(out0[-1200:])

    for label, marker, mutate in MUTATIONS:
        io.open(bad_readme, "w", encoding="utf-8", newline="").write(original)
        io.open(bad_doc, "w", encoding="utf-8", newline="").write(original_doc)
        if mutate is None:
            # the port's own source changes: rebuild the package copy
            shutil.rmtree(os.path.join(tmp, "moonbit_doubleML"))
            shutil.copytree(PKG, os.path.join(tmp, "moonbit_doubleML"),
                            ignore=shutil.ignore_patterns("_build", "_verify",
                                                         "target", ".git"))
            n = rename_struct(os.path.join(tmp, "moonbit_doubleML"),
                              "DoubleMLDIDCrossSection",
                              "SantAnnaZhao2020")
            print("       (renamed the port's struct in %d file(s))" % n)
        else:
            # A mutation that cannot be APPLIED is a harness problem, not a
            # crash: the control must still report the other mutations, and
            # it must say that this one never ran.  A control that dies on
            # the first bad input reports nothing at all.
            try:
                t, d = mutate(original, original_doc)
            except SystemExit as exc:
                ok = False
                harness.append("%s -- could not be applied (%s)"
                               % (label, exc))
                print("  %-8s  %s  (the mutation could not be applied)"
                      % ("ERROR  ", label))
                continue
            io.open(bad_readme, "w", encoding="utf-8", newline="").write(t)
            io.open(bad_doc, "w", encoding="utf-8", newline="").write(d)
        rc, out = run_gate()
        detected = rc != 0 and marker in out
        ok &= detected
        print("  %-8s  %s  (exit=%d)" % ("DETECTED" if detected else "MISSED  ",
                                         label, rc))
        if not detected:
            missed.append(label)
            print("      the gate did not fail, or failed for another reason"
                  " (expected %r in its output)" % marker)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# and the real tree must still pass
rc, out = run_gate(GATE)
print("  %-8s  the unmutated README in the tree passes (exit=%d)" %
      ("PASS" if rc == 0 else "BROKEN", rc))
ok &= rc == 0
if rc != 0:
    harness.append("the real tree does not pass")
    print(out[-1200:])

# The two kinds of failure are counted SEPARATELY, and the summary says which
# is which: "a mutation was missed" means the gate stopped biting, and "the
# harness is broken" means the control could not set the test up.  A control
# that cannot tell them apart cannot be read by a driver that proves the
# control bites.
print()
print("mutations missed: %d of %d" % (len(missed), len(MUTATIONS)))
print("harness problems: %d" % len(harness))
for h in harness:
    print("    %s" % h)
for m in missed:
    print("    MISSED: %s" % m)

print()
if ok:
    print("GATE DISCRIMINATES -- %d mutations, every one caught for the right "
          "reason" % len(MUTATIONS))
else:
    print("GATE DOES NOT DISCRIMINATE")
sys.exit(0 if ok else 1)
