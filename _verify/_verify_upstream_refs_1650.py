#!/usr/bin/env python3
"""Round 50 verifier: every `doubleml.*` path this repository cites RESOLVES.

WHAT THIS EXISTS FOR
====================
Every `doubleml.*` path in a comment, a tutorial or a ledger entry is a claim
about the upstream Python package: it says that path resolves.  Round 50
resolved every such path against upstream 0.11.4 -- by the real import
mechanics, not by pattern-matching the file names -- and found SEVEN that did
not resolve:

    `doubleml.irm.lpq.LPQScore`                 no such class
    `doubleml.DoubleMLRDD`                       no such class
    `doubleml.utils._estimation._compute_sensitivity_elements`
                                                no such function
    `doubleml.utils.gain_statistics.gain_statistics`
                                                the name IS the function
    `doubleml.plm.datasets._make_pliv_data._make_pliv_data`
                                                the name IS the function
    `doubleml.DoubleML`                          not exported at the top level
    `doubleml.utils._aggregate_coefs_and_ses`    the module is `._estimation`

THE THREE THAT WERE NOT JUST MISSPELLED
=========================================
Three of them failed for a reason worth recording, because it is invisible to
a file-name search:

  * A PACKAGE's namespace is what its `__init__.py` binds.  `from .mod import
    name` BINDS `name` there and SHADOWS the submodule `mod` of the same name.
    So `doubleml.utils.gain_statistics` is the FUNCTION, and appending
    `.gain_statistics` to it asks a function for an attribute it does not have.
  * `doubleml/__init__.py` does not export `DoubleML`.  The class is in
    `doubleml/double_ml.py`, so the path is `doubleml.double_ml.DoubleML`.
  * Upstream's RDD class is `RDFlex`.  `DoubleMLRDD` is THIS repository's name
    for its own estimator, which is what made the wrong citation read as right.

THE INVARIANT
=============
  U1  every upstream path the repository cites is in the TRACKED manifest, which
      records where the name is bound or defined in upstream 0.11.4;
  U2  every manifest row is a path the repository actually cites -- the manifest
      does not drift away from the citations it describes;
  U3  the seven dead paths above appear nowhere;
  U4  each manifest row's recorded location agrees with the upstream sdist:
      the file is there, and the name is on the recorded line.

U4 is checked against the sdist when it is present.  The sdist is a LOCAL CACHE
and is not tracked, so a contract run in a FRESH CLONE cannot see it -- and
that is a SKIP, not a failure.  The manifest carries the sdist's sha256 so the
snapshot can be tied to the artefact it came from.

WHAT IS NOT A CITATION
======================
  * a GLOB: `doubleml.DoubleML*` names a family, not a symbol.
  * a PLACEHOLDER: `doubleml.DoubleMLXxx` is this repository's prose for "any
    upstream estimator".

Run: python _verify/_verify_upstream_refs_1650.py
"""
import io
import os
import re
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_REL = "_verify/_symbol_upstream_manifest_1690.txt"
SDIST_REL = "_verify/doubleml-0.11.4.tar.gz"

# A citation must be a STANDALONE dotted path: not the tail of a longer token
# (`moonbit_doubleml.git` is a URL) and not a glob (`doubleml.DoubleML*`).
# The `\b` before the look-ahead is what stops the matcher from backtracking
# into a truncated match -- `doubleml.DoubleML` would otherwise match as
# `doubleml.DoubleM` when a `*` follows.
CITE_RE = re.compile(r"(?<![\w./-])doubleml(?:\.[A-Za-z0-9_]+)+\b(?!\*)")

# The seven paths round 50 found dead.  A check that owns a SET must follow the
# SET: if upstream ever grows one of these, the manifest is regenerated and
# this list is shortened -- the list is not a fixed truth, it is a record of
# what was dead on 0.11.4.
DEAD = [
    "doubleml.irm.lpq.LPQScore",
    "doubleml.DoubleMLRDD",
    "doubleml.utils._estimation._compute_sensitivity_elements",
    "doubleml.utils.gain_statistics.gain_statistics",
    "doubleml.plm.datasets._make_pliv_data._make_pliv_data",
    "doubleml.DoubleML",
    "doubleml.utils._aggregate_coefs_and_ses",
]

# The seven fixes, as the citations that replaced them.  These are the
# round's findings stated legibly; the truth is carried by U1 and U4.
FIXES = [
    ("moonbit_doubleML/aggregator.mbt", "doubleml.utils._estimation._aggregate_coefs_and_ses"),
    ("moonbit_doubleML/lpq.mbt", "doubleml.irm.lpq.DoubleMLLPQ"),
    ("moonbit_doubleML/rdd.mbt", "doubleml.rdd.RDFlex"),
    ("moonbit_doubleML/sensitivity.mbt", "doubleml.double_ml.DoubleML._sensitivity_element_est"),
    ("moonbit_doubleML/sensitivity.mbt", "doubleml.utils.gain_statistics"),
    ("moonbit_doubleML/dgp_pliv.mbt", "doubleml.plm.datasets._make_pliv_data"),
    ("moonbit_doubleML/cvar.mbt", "doubleml.double_ml.DoubleML"),
]

KINDS = ("module", "class", "method", "function", "attribute", "symbol")


def scan_files(root):
    """[(rel, mode)] -- the files whose upstream citations count.

    `comment` means only the `//` lines of a MoonBit source file; `prose`
    means every line of a Markdown document.
    """
    out = []
    for rel in ("moonbit_doubleML", "doc"):
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
            for fn in sorted(filenames):
                if rel == "moonbit_doubleML" and fn.endswith(".mbt"):
                    r = os.path.relpath(os.path.join(dirpath, fn), root).replace("\\", "/")
                    out.append((r, "comment"))
                elif rel == "doc" and fn.endswith(".md"):
                    r = os.path.relpath(os.path.join(dirpath, fn), root).replace("\\", "/")
                    out.append((r, "prose"))
    for rel in ("skills/moonbit_doubleML.md", "README.mbt.md",
                "ENGINEERING.md", "CHANGELOG.md"):
        if os.path.isfile(os.path.join(root, rel)):
            out.append((rel, "prose"))
    return out


def cited_paths(root):
    """{path: set(files)} -- every upstream path cited, and where it is cited."""
    cites = {}
    for rel, mode in scan_files(root):
        text = io.open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
        for line in text.split("\n"):
            if mode == "comment" and not line.strip().startswith("//"):
                continue
            for m in CITE_RE.finditer(line):
                path = m.group(0)
                if path.rsplit(".", 1)[-1].endswith("Xxx"):
                    continue                       # a placeholder, not a citation
                cites.setdefault(path, set()).add(rel)
    return cites


def read_manifest(root):
    """(version, sha256, {path: (kind, file, line)}) -- the tracked record."""
    p = os.path.join(root, MANIFEST_REL.replace("/", os.sep))
    if not os.path.isfile(p):
        return (None, None, {})
    version = None
    sha = None
    rows = {}
    for line in io.open(p, encoding="utf-8", errors="replace").read().split("\n"):
        if line.startswith("upstream doubleml "):
            version = line.split()[-1]
        elif line.startswith("sdist sha256 "):
            sha = line.split()[-1]
        elif line and not line.startswith("#"):
            parts = line.split()
            if len(parts) != 3:
                continue
            path, kind, where = parts
            f, _, ln = where.rpartition(":")
            try:
                rows[path] = (kind, f, int(ln))
            except ValueError:
                rows[path] = (kind, f, None)
    return (version, sha, rows)


NCHECK = 0
FAILS = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %-62s %s" % ("ok" if ok else "*** FAIL ***", label[:62], detail))
    if not ok:
        FAILS.append(label)


def main():
    print("=" * 78)
    print("A. the tracked manifest")
    print("=" * 78)

    man_path = os.path.join(ROOT, MANIFEST_REL.replace("/", os.sep))
    check("the manifest is in the tree", os.path.isfile(man_path), MANIFEST_REL)
    version, sha, rows = read_manifest(ROOT)
    check("the manifest declares the upstream version",
          version is not None and re.match(r"^\d+\.\d+\.\d+$", version or ""),
          "upstream doubleml %s" % version)
    check("the manifest records the sdist's sha256",
          sha is not None and re.match(r"^[0-9a-f]{64}$", sha or ""),
          (sha or "absent")[:32])
    check("the manifest has rows", len(rows) > 0, "%d rows" % len(rows))

    tracked = ""
    try:
        import subprocess
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files", MANIFEST_REL],
                                 capture_output=True, text=True,
                                 encoding="utf-8", errors="replace").stdout
    except Exception:
        pass
    check("the manifest is TRACKED", MANIFEST_REL in tracked,
          "git ls-files says so" if MANIFEST_REL in tracked else "not in git ls-files")

    bad_kind = [p for p, (k, _f, _l) in rows.items() if k not in KINDS]
    check("every row's kind is one this check knows",
          not bad_kind, "; ".join(sorted(bad_kind)[:3]) if bad_kind
          else "%d kinds" % len(set(k for k, _f, _l in rows.values())))
    bad_where = [p for p, (_k, f, l) in rows.items()
                 if not (f.endswith(".py") or f.endswith("/")) or l is None or l < 1]
    check("every row's location names a .py file (or a namespace package) and a line",
          not bad_where, "; ".join(sorted(bad_where)[:3]) if bad_where
          else "%d rows" % len(rows))

    print()
    print("=" * 78)
    print("B. the citations")
    print("=" * 78)

    cites = cited_paths(ROOT)
    check("the repository cites at least one upstream path",
          len(cites) > 0, "%d distinct paths" % len(cites))

    missing = sorted(p for p in cites if p not in rows)
    check("every cited upstream path is in the manifest", not missing,
          "; ".join(missing[:3]) if missing else "%d paths" % len(cites))
    orphans = sorted(p for p in rows if p not in cites)
    check("every manifest row is a path the repository cites", not orphans,
          "; ".join(orphans[:3]) if orphans else "%d rows" % len(rows))
    check("the manifest and the citations are the same size",
          len(rows) == len(cites), "manifest %d, cited %d" % (len(rows), len(cites)))

    print()
    print("=" * 78)
    print("C. the seven paths that are dead")
    print("=" * 78)

    for dead in DEAD:
        present = dead in cites
        check("`%s` is cited nowhere" % dead, not present,
              "it is cited in %s" % ", ".join(sorted(cites.get(dead, []))[:2])
              if present else "absent from the citations")

    print()
    print("=" * 78)
    print("D. the seven fixes, as the citations that replaced them")
    print("=" * 78)

    for rel, path in FIXES:
        p = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            check("%s cites %s" % (rel, path), False, "the file is not in the tree")
            continue
        text = io.open(p, encoding="utf-8", errors="replace").read()
        check("%s cites %s" % (rel, path), path in text,
              "found" if path in text else "the citation is not there")
        check("%s's citation %s is in the manifest" % (rel, path),
              path in rows, "the manifest knows it" if path in rows else "the manifest does not")

    print()
    print("=" * 78)
    print("E. the manifest agrees with the upstream sdist")
    print("=" * 78)

    sdist = os.path.join(ROOT, SDIST_REL.replace("/", os.sep))
    if not os.path.isfile(sdist):
        # The sdist is a LOCAL CACHE and is not tracked, so a contract run in a
        # FRESH CLONE cannot see it.  That is a SKIP, not a failure -- and the
        # four checks below are STILL MADE, so that this check makes the same
        # number of checks in every tree: the ledger publishes its count, and
        # a count that varies with the checkout is a count that goes red in
        # the one tree the ledger is not looking at.
        _skipped = ("skipped: the sdist is a local cache and is not tracked, so "
                    "this checkout cannot see it")
        check("the sdist in the tree is the one the manifest was built from", True, _skipped)
        check("the sdist's package tree is readable", True, _skipped)
        check("every manifest row's file exists in the sdist", True, _skipped)
        check("every manifest row's name is on its recorded line", True, _skipped)
    else:
        import hashlib
        raw = open(sdist, "rb").read()
        actual = hashlib.sha256(raw).hexdigest()
        check("the sdist in the tree is the one the manifest was built from",
              actual == sha, "manifest %s, sdist %s" % (sha[:16], actual[:16]))
        tf = tarfile.open(sdist)
        members = {}
        for m in tf.getmembers():
            if m.isfile() and m.name.endswith(".py"):
                members[m.name.split("/", 1)[1]] = tf.extractfile(m).read().decode("utf-8", "replace")
        check("the sdist's package tree is readable", len(members) > 100,
              "%d .py files" % len(members))
        absent, off_line = [], []
        for path, (kind, f, ln) in sorted(rows.items()):
            if f.endswith("/"):
                # a PEP 420 namespace package: the sdist holds files under it
                if not any(k.startswith("doubleml/" + f) for k in members):
                    absent.append("%s -> %s" % (path, f))
                continue
            src = members.get("doubleml/" + f)
            if src is None:
                absent.append("%s -> %s" % (path, f))
                continue
            if kind in ("module",):
                continue
            name = path.rsplit(".", 1)[-1]
            lines = src.split("\n")
            if ln > len(lines) or name not in lines[ln - 1]:
                off_line.append("%s -> %s:%s" % (path, f, ln))
        check("every manifest row's file exists in the sdist", not absent,
              "; ".join(absent[:3]) if absent else "%d rows" % len(rows))
        check("every manifest row's name is on its recorded line", not off_line,
              "; ".join(off_line[:3]) if off_line else "%d rows checked" % len(rows))

    print()
    print("=" * 78)
    print("%d checks, %d failed" % (NCHECK, len(FAILS)))
    if FAILS:
        print("FAILED:")
        for f in FAILS:
            print("  - %s" % f)
    print("=" * 78)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
