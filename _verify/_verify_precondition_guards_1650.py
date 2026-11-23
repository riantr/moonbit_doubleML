#!/usr/bin/env python3
"""Pin the precondition guards that the analyzer QA found missing.

WHAT THIS PINS
==============
Two families of public entry points took an unchecked value into an array
index or into an allocation size:

1. THE CLUSTER-ID SCAN.  Seven places in the library compute `max_cid` over
   `cluster_ids` and then size a per-cluster array with `max_cid + 1`.
   Four of them checked the id's sign first (`require(cluster_ids[i] >= 0)`);
   three did not, so a cluster id of -1 passed `require(max_cid >= 0)` and
   then indexed the per-cluster accumulator at -1.

   MEASURED (before the fix), on the published 0.164.64 bytes:

     cluster_sandwich_variance (HAS the guard)  -> "precondition failed at
       sandwich.mbt:551:7-551:22@riantr/moonbit_doubleML"
     irm_style_sensitivity_cluster  (NO guard)   -> PanicError, exit
       3221226505, no "precondition failed" line

   The discriminator is that line. A precondition failure names the file
   and the line; a raw MoonBit panic does not.

   `irm_style_sensitivity_cluster_from_elements` additionally lacked the
   `require(cluster_ids.length() == n)` its sibling has, so a SHORT
   `cluster_ids` read past its end.

2. THE MATRIX DIMENSIONS.  `Matrix::zeros` / `Matrix::ones` /
   `Matrix::from_array` took `nrows` / `ncols` unchecked. A negative
   dimension reached `Array::make` with a negative size, which PANICS
   (`moonbit_make_double_array_raw`); and a negative pair whose product is
   POSITIVE (`zeros(-1, -3)`) did not even panic -- it built a matrix whose
   own `rows()` / `cols()` disagree with its data, silently.

HOW IT MEASURES
===============
The probe (`_verify/_probe_preconditions_1650.mbt`) is COPIED INTO the
library package, the package is flipped to an executable, and one mode per
process is run. The PROCESS OUTCOME is the verdict, because the difference
between the two failure modes is exactly what is being pinned.

The structural half is a source scan over the same tree: every cluster-id
scan must validate the id's sign, and every public Matrix constructor must
reject a negative dimension. The structural check is what covers the sites
the runtime probe does not reach (`DoubleMLPLR::sensitivity_analysis_cluster`
needs a fitted model to drive).

THE CONTROL ARM
===============
`--falsify` removes the guards from the COPY and runs the same modes and
the same structural scan. Every guard-dependent expectation must then FAIL,
and the control expectations (valid input still works) must still hold. If
removing a guard changes nothing, the check does not bite, and the
verifier says so: a check that cannot fail is not a check.

    python -X utf8 _verify/_verify_precondition_guards_1650.py --falsify
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
PROBE = os.path.join(ROOT, "_verify", "_probe_preconditions_1650.mbt")

FALSIFY = "--falsify" in sys.argv

# The pre-fix bodies. The falsify arm puts these back, so the control arm
# reproduces the PRE-FIX source rather than a half-edited one.
#
# Why whole bodies and not just the guard line: `Matrix::zeros` and
# `Matrix::ones` gained their `try { require(...) } catch { ... }` wrapper
# together with the guard. Deleting only the `require` would leave a `try`
# whose body can no longer raise, which the compiler rejects with
# `partial_match` -- a compile error, not a behaviour. The pre-fix body is
# the honest way to say "the guard was not there".
PRE_FIX = [
    ("matrix.mbt", "pub fn Matrix::zeros(", """pub fn Matrix::zeros(nrows : Int32, ncols : Int32) -> Matrix {
  let data = Array::make(nrows * ncols, 0.0)
  { nrows, ncols, data, }
}"""),
    ("matrix.mbt", "pub fn Matrix::ones(", """pub fn Matrix::ones(nrows : Int32, ncols : Int32) -> Matrix {
  let data = Array::make(nrows * ncols, 1.0)
  { nrows, ncols, data, }
}"""),
]

# Guard lines the falsify arm deletes outright. These sit in functions that
# already raise on their own (`require` with no local `try`), so deleting
# the line removes the guard without changing the shape of the code.
GUARDS = [
    ("matrix.mbt", "require(nrows >= 0 && ncols >= 0)"),
    ("sensitivity.mbt", "require(cluster_ids[i] >= 0)"),
    ("sensitivity.mbt", "require(cluster_ids.length() == n)"),
    ("plr.mbt", "require(cluster_ids[i] >= 0)"),
]

CLEAN = "precondition failed at"
PANIC = "PanicError"

MAIN_TEMPLATE = r"""fn main {
  try {
    probe_dispatch("__MODE__")
  } catch {
    PreconditionError::Violated(loc) =>
      println("PROBE CAUGHT PRECONDITION at " + loc.to_string())
    err => println("PROBE CAUGHT OTHER: \{err}")
  }
}
"""

fails = []
N = 0


def check(label, cond, detail=""):
    global N
    N += 1
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        print("        %s" % str(detail).replace("\n", " | ")[:400])
        fails.append("%s -- %s" % (label, detail))
    return cond


# --------------------------------------------------------------------- source


def read_lines(path):
    return io.open(path, encoding="utf-8", errors="replace").read().split("\n")


def library_sources(libdir):
    out = []
    for name in sorted(os.listdir(libdir)):
        if not name.endswith(".mbt"):
            continue
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            continue
        out.append((name, os.path.join(libdir, name)))
    return out


def scan_cluster_sites(libdir):
    """Every scan that computes `max_cid` over `cluster_ids` must validate
    the id's sign inside the same loop body.

    The four already-guarded sites spell the guard two ways --
    `require(cluster_ids[i] >= 0)` and `require(c >= 0)` -- so the scan
    looks for a `require` that mentions `>= 0` within the loop that
    computes `max_cid`, rather than for one exact spelling.
    """
    sites = []
    for name, path in library_sources(libdir):
        lines = read_lines(path)
        for i, ln in enumerate(lines):
            if "> max_cid" not in ln:
                continue
            window = lines[max(0, i - 6):i + 1]
            guarded = any("require(" in w and ">= 0" in w for w in window)
            sites.append((name, i + 1, guarded, ln.strip()))
    return sites


def scan_matrix_guards(libdir):
    """The public Matrix constructors must reject a negative dimension.

    `Matrix::identity` is guarded TRANSITIVELY: it builds through
    `Matrix::zeros`, so the check for it is that it still delegates.
    """
    path = os.path.join(libdir, "matrix.mbt")
    lines = read_lines(path)
    out = []
    for fn in ("Matrix::zeros", "Matrix::ones", "Matrix::from_array"):
        idx = None
        for i, ln in enumerate(lines):
            if ln.startswith("pub fn " + fn + "("):
                idx = i
                break
        if idx is None:
            out.append((fn, None, False))
            continue
        body = lines[idx:idx + 24]
        guarded = any("require(" in b and ">= 0" in b for b in body)
        out.append((fn, idx + 1, guarded))
    idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("pub fn Matrix::identity("):
            idx = i
            break
    if idx is None:
        out.append(("Matrix::identity", None, False))
    else:
        body = lines[idx:idx + 12]
        out.append(("Matrix::identity", idx + 1,
                    any("Matrix::zeros(" in b for b in body)))
    return out


# --------------------------------------------------------------------- runtime


def replace_block(lines, header, new_text):
    """Replace the top-level function whose header line starts with
    `header` by `new_text`. Returns (lines, found)."""
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith(header):
            start = i
            break
    if start is None:
        return lines, False
    end = None
    for j in range(start + 1, len(lines)):
        if lines[j] == "}":
            end = j
            break
    if end is None:
        return lines, False
    out = lines[:start] + new_text.split("\n") + lines[end + 1:]
    return out, True


def build_package(tmp, falsify):
    dst = os.path.join(tmp, "lib")
    shutil.copytree(LIB, dst,
                    ignore=shutil.ignore_patterns("_build", "target", ".git"))
    shutil.copy2(PROBE, os.path.join(dst, "_probe_preconditions_1650.mbt"))
    pkgp = os.path.join(dst, "moon.pkg")
    t = io.open(pkgp, encoding="utf-8", newline="").read()
    if "pkgtype" not in t:
        t = t.rstrip("\n") + '\n\npkgtype(kind: "executable")\n'
    io.open(pkgp, "w", encoding="utf-8", newline="").write(t)
    if falsify:
        for fname, header, body in PRE_FIX:
            p = os.path.join(dst, fname)
            lines = read_lines(p)
            lines, found = replace_block(lines, header, body)
            if not found:
                print("   !! falsify could not restore %s in %s" % (header, fname))
            io.open(p, "w", encoding="utf-8", newline="").write("\n".join(lines))
        for fname, guard in GUARDS:
            p = os.path.join(dst, fname)
            src = io.open(p, encoding="utf-8", newline="").read()
            kept = [l for l in src.split("\n") if l.strip() != guard]
            io.open(p, "w", encoding="utf-8", newline="").write("\n".join(kept))
    return dst


def run_mode(pkgdir, mode):
    mainp = os.path.join(pkgdir, "main.mbt")
    io.open(mainp, "w", encoding="utf-8", newline="\n").write(
        MAIN_TEMPLATE.replace("__MODE__", mode))
    r = subprocess.run(["moon", "run", "--target", "native", pkgdir],
                       cwd=pkgdir, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=600)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


# What each mode must show, per arm.
#
#   normal  -- the shipped tree, guards in place
#   falsify -- the same tree with the guards deleted
#
# `control` modes are the ones that must NOT change between the arms: they
# prove the guards do not over-reject valid input.
NORMAL = {
    "cluster_ok":    ("survived", False),
    "cluster_neg":   ("precondition", False),
    "cluster_len":   ("precondition", False),
    "matrix_ok":     ("survived", False),
    "matrix_neg":    ("clean_abort", False),
    "matrix_negneg": ("clean_abort", False),
}
FALSIFIED = {
    "cluster_ok":    ("survived", False),
    "cluster_neg":   ("raw_panic", True),
    "cluster_len":   ("raw_panic", True),
    "matrix_ok":     ("survived", False),
    "matrix_neg":    ("raw_panic", True),
    "matrix_negneg": ("silent_inconsistent", True),
}


def outcome(kind, rc, out):
    if kind == "survived":
        return rc == 0 and "SURVIVED" in out
    if kind == "precondition":
        # The library RAISES, and the probe catches it: the process
        # survives and says so.
        return rc == 0 and "CAUGHT PRECONDITION" in out
    if kind == "clean_abort":
        # The library ABORTS: the process dies, but names the site.
        return rc != 0 and CLEAN in out
    if kind == "raw_panic":
        return rc != 0 and PANIC in out and CLEAN not in out
    if kind == "silent_inconsistent":
        return rc == 0 and "matrix_negneg SURVIVED rows=-1" in out
    return False


def main():
    print("== precondition guards ==")
    print("library : %s" % LIB)
    print("mode    : %s" % ("FALSIFY (control arm)" if FALSIFY else "NORMAL"))
    print("")

    # ---- the structural half, over the shipped tree -----------------------
    sites = scan_cluster_sites(LIB)
    print("-- cluster-id scans --")
    for name, ln, guarded, text in sites:
        print("   %s:%d  %s" % (name, ln, text))
    print("")
    matrices = scan_matrix_guards(LIB)
    print("-- Matrix constructors --")
    for fn, ln, guarded in matrices:
        print("   %s (line %s)" % (fn, ln))
    print("")

    if FALSIFY:
        # The control arm must FAIL every guard-dependent expectation and
        # must still PASS every control expectation.
        tmp = tempfile.mkdtemp(prefix="dblib_falsify_")
        try:
            pkg = build_package(tmp, True)
            # The structural checks must also bite on the patched copy.
            psites = scan_cluster_sites(pkg)
            pun = [s for s in psites if not s[2]]
            check("falsify the cluster-id scan check bites", len(pun) > 0,
                  "no unguarded scan after the patch")
            pmat = scan_matrix_guards(pkg)
            pbad = [m for m in pmat if not m[2]]
            check("falsify the Matrix constructor check bites", len(pbad) > 0,
                  "no unguarded constructor after the patch")
            for mode in sorted(set(NORMAL) | set(FALSIFIED)):
                nkind, _ = NORMAL[mode]
                fkind, changes = FALSIFIED[mode]
                rc, out = run_mode(pkg, mode)
                fgot = outcome(fkind, rc, out)
                ngot = outcome(nkind, rc, out)
                detail = "rc=%s falsified=%s normal=%s out=%s" % (
                    rc, fgot, ngot, out.strip().replace("\n", " | ")[:260])
                if changes:
                    # The guard is what separates the two outcomes: the
                    # patched tree must show the unguarded behaviour AND
                    # must NOT show the guarded one.
                    check("falsify %-13s shows the unguarded outcome" % mode,
                          fgot and not ngot, detail)
                else:
                    # A control must behave the SAME in both arms.
                    check("falsify %-13s control still works" % mode,
                          fgot and ngot, detail)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        print("")
        print("%d checks, %d failed" % (N, len(fails)))
        for f in fails:
            print("  - %s" % f)
        print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
        return 1 if fails else 0

    # ---- the normal arm ---------------------------------------------------
    unguarded = [s for s in sites if not s[2]]
    check("every cluster-id scan validates the id's sign",
          not unguarded,
          "unguarded: %s" % ", ".join("%s:%d" % (s[0], s[1]) for s in unguarded))
    bad_matrix = [m for m in matrices if not m[2]]
    check("every public Matrix constructor rejects a negative dimension",
          not bad_matrix,
          "unguarded: %s" % ", ".join(str(m[0]) for m in bad_matrix))

    tmp = tempfile.mkdtemp(prefix="dblib_probe_")
    try:
        pkg = build_package(tmp, False)
        for mode, (kind, _) in sorted(NORMAL.items()):
            rc, out = run_mode(pkg, mode)
            check("%-13s -> %s" % (mode, kind), outcome(kind, rc, out),
                  "rc=%s out=%s" % (rc, out.strip().replace("\n", " | ")[:220]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    print("%d checks, %d failed" % (N, len(fails)))
    for f in fails:
        print("  - %s" % f)
    print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
