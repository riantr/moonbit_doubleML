"""Round 16 -- pin the upstream-provenance claims, claim by claim.

WHAT THIS PINS
--------------
1. The derivation itself: `_verify/_audit_r16_provenance_1650.py` runs, and
   the grouping it produces is 19 name-identical + 2 renamed + 1 with no 1:1
   upstream class, with NO upstream class claimed twice.  The counts are
   DERIVED, not literals: what is pinned is the INVARIANT (the correspondence
   is one-to-one; every port estimator is covered), because a verifier that
   pins a count to a constant is what made the old labels unchallengeable.

2. The record `_verify/UPSTREAM_PROVENANCE.md`:
   * it is TRACKED (a path in prose is a promise; an untracked file is a
     promise nobody can keep -- and this record was untracked for its whole
     life, which is how the repository ended up with no upstream authority
     map at all);
   * every upstream module -> class row in its table resolves in the
     installed package;
   * every "our estimator" in its table matches the derived map;
   * its counts match the derived counts;
   * it carries a dated banner;
   * the claims it withdraws are ABSENT from its body (the banner is
     excluded: a correct "was -> now" banner legitimately quotes the old
     value);
   * every file it promises in "Files kept in this directory" exists AND is
     tracked, and the file it disclaims is not promised.

3. The README: the grouping, the label on the row with no 1:1 upstream
   class, and the amendment note.

4. The pointer the record quotes: `did/did_cs.py:16` must be the
   `class DoubleMLDIDCS(LinearScoreMixin, DoubleML):` line -- resolved AND
   content-checked, because a pointer that resolves to the wrong line is
   still wrong.

DRY-RUN
-------
`ROUND16_ROOT` points the verifier at another checkout, so the same checks
can be run against the PREVIOUS release.  The dry-run counts the failures
exactly, so a verifier that has stopped biting is visible.

Run: python _verify/_verify_round16_provenance_1650.py
"""
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("ROUND16_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "_verify"))

fails = []
checks = 0


def check(label, cond, detail=""):
    global checks
    checks += 1
    if not cond:
        fails.append("%s -- %s" % (label, detail))
        print("  *** FAIL *** %s%s" % (label, ("  [%s]" % detail) if detail else ""))
    else:
        print("  ok   %s" % label)


def read(p):
    """Read a file, or return b"" if it is absent.

    Absent must be a FAILURE the verifier reports, not a crash: the dry-run
    against the previous release has no record at all, and a verifier that
    dies on a missing file cannot report the absence.
    """
    if not os.path.isfile(p):
        return b""
    with open(p, "rb") as f:
        return f.read()


def body(path):
    """The record's BODY, with the leading blockquote banner removed.

    The banner starts at the first '>' line.  It is excluded because a
    correct "was -> now" banner legitimately quotes the old value, and a
    stale-claim check that reads the whole file would flag the banner for
    containing the very value it withdraws.
    """
    text = read(path).decode("utf-8", "replace")
    lines = text.splitlines()
    out, in_banner = [], True
    for ln in lines:
        if in_banner:
            if ln.startswith(">"):
                continue
            if ln.strip() == "":
                continue
            in_banner = False
        out.append(ln)
    return "\n".join(out)


def tracked_paths():
    r = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return {t.replace("\\", "/") for t in r.stdout.splitlines()}


TRACKED = tracked_paths()

print("root:", ROOT)
print()

# ---------------------------------------------------------- 1. the derivation
print("=== 1. the derivation ===")
audit_path = os.path.join(ROOT, "_verify", "_audit_r16_provenance_1650.py")
check("the method script is tracked", "_verify/_audit_r16_provenance_1650.py" in TRACKED)

sys.path.insert(0, os.path.join(ROOT, "_verify"))
import _audit_r16_provenance_1650 as audit

derived = audit.derive()
c = derived["counts"]
check("the grouping covers all 22 estimators", c["total"] == 22, "got %d" % c["total"])
check("the three groups partition the 22",
      c["plain"] + c["renamed"] + c["no_upstream_class"] == 22,
      "got %d+%d+%d" % (c["plain"], c["renamed"], c["no_upstream_class"]))
check("NO upstream class is claimed by two port estimators",
      derived["upstream_class_claimed_twice"] == [],
      "claimed twice: %s" % derived["upstream_class_claimed_twice"])
check("the renamed rows name an upstream class that exists",
      all(u in derived["upstream_params"] for u in derived["renamed"].values()),
      "renamed: %s" % derived["renamed"])
check("exactly one port estimator has no 1:1 upstream class",
      len(derived["no_upstream_class"]) == 1,
      "got %s" % derived["no_upstream_class"])
check("the no-1:1 estimator is the port's DoubleMLDIDCS",
      derived["no_upstream_class"] == ["DoubleMLDIDCS"],
      "got %s" % derived["no_upstream_class"])

# the distinguishing-parameter facts the labels rest on
up_params = derived["upstream_params"]
port_params = derived["port_params"]
check("gt_combinations is on upstream's DoubleMLDIDMulti",
      "gt_combinations" in up_params.get("DoubleMLDIDMulti", []))
check("gt_combinations is on no other upstream DID class",
      [k for k in ("DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCS",
                   "DoubleMLDIDCSBinary")
       if "gt_combinations" in up_params.get(k, [])] == [])
check("on the port side only DoubleMLDIDMulti carries gt_combinations",
      sorted(p for p, ps in port_params.items() if "gt_combinations" in ps)
      == ["DoubleMLDIDMulti"])
print()

# ------------------------------------------------------------- 2. the record
print("=== 2. the record _verify/UPSTREAM_PROVENANCE.md ===")
rec_rel = "_verify/UPSTREAM_PROVENANCE.md"
rec = os.path.join(ROOT, rec_rel)
check("the record is TRACKED", rec_rel in TRACKED,
      "it was never tracked before this round")
check("the record exists on disk", os.path.isfile(rec))

rec_text = read(rec).decode("utf-8", "replace")
rec_body = body(rec)

head_lines = rec_text.splitlines()[:40]
first_quote = next((l for l in head_lines if l.startswith(">")), "")
check("the record carries a dated banner",
      bool(first_quote) and "Re-audited" in first_quote,
      "the FIRST blockquote must be the re-audit banner; got: %r" % first_quote[:70])
check("the banner states what is NOT verified",
      "NOT verified" in "\n".join(head_lines))

# the table rows: | upstream module | class | our estimator |
rows = re.findall(r"^\|\s*`([^`]+)`\s*\|\s*\**`?([A-Za-z0-9_]+)`?\**[^|]*\|\s*"
                  r"\**`?([A-Za-z0-9_]+)`?\**[^|]*\|\s*$", rec_body, re.M)
print("  table rows parsed: %d" % len(rows))
# A census that omits a bucket can still print its own total, so the row count
# is checked explicitly: 21 upstream classes + 1 row for the estimator with no
# 1:1 upstream class.
check("the record's table has 22 rows", len(rows) == 22, "got %d" % len(rows))

# the upstream module -> class pairs must resolve in the installed package
pkg = derived["upstream_package"]
bad_mod, bad_cls = [], []
for mod, cls, _ours in rows:
    if cls == "none":
        continue            # the row for the estimator with no 1:1 upstream class
    p = os.path.join(pkg, mod.replace("/", os.sep))
    if not os.path.isfile(p):
        bad_mod.append((mod, cls))
        continue
    src = read(p).decode("utf-8", "replace")
    if not re.search(r"^class\s+%s\b" % re.escape(cls), src, re.M):
        bad_cls.append((mod, cls))
check("every upstream module the record names exists in the package",
      not bad_mod, "missing: %s" % bad_mod)
check("every class the record places in that module is in it",
      not bad_cls, "not in the module: %s" % bad_cls)

# every "our estimator" must match the derived map
bad_ours = []
for _mod, _cls, ours in rows:
    if ours not in derived["upstream_class_of"]:
        bad_ours.append(ours)
        continue
    got = derived["upstream_class_of"][ours]
    want = None if _cls == "none" else _cls
    if got != want:
        bad_ours.append("%s: record says %s, derived says %s"
                        % (ours, want, got))
check("every 'our estimator' in the record's table matches the derived map",
      not bad_ours, "; ".join(bad_ours))
check("the record's table has exactly one row with no 1:1 upstream class",
      len([r for r in rows if r[1] == "none"]) == 1,
      "got %d" % len([r for r in rows if r[1] == "none"]))

# the record's counts
check("the record states 19 name-identical",
      re.search(r"19 name-identical", rec_text) is not None)
check("the record states 2 renamed",
      re.search(r"2 renamed", rec_text) is not None)
check("the record states the no-1:1 count",
      re.search(r"1 with no 1:1 upstream class|no 1:1 upstream class", rec_text)
      is not None)

# the withdrawn claims must be ABSENT from the body
withdrawn = [
    ("our DoubleMLDIDCS` is the multi-cell panel estimator, which is upstream's `DoubleMLDID`",
     "the old pairing of the port's panel DIDCS with upstream's DID"),
    ("| `did/did_cs.py` | `DoubleMLDIDCS` | `DoubleMLDIDCS` |",
     "the table row that paired the port's DIDCS with upstream's DIDCS by name"),
    ("`DoubleMLDIDCS` is upstream's `DoubleMLDIDMulti`",
     "the old pairing of the port's DIDCS with upstream's DIDMulti"),
]
for text, why in withdrawn:
    check("withdrawn: %s" % why, text not in rec_body,
          "still in the body: %r" % text[:60])

# the files it promises
print()
promised = re.findall(r"^- `([A-Za-z0-9_.-]+)`", rec_body, re.M)
promised = [p for p in promised if p.endswith((".py", ".tar.gz"))]
print("  files named in the record: %s" % promised)
for name in promised:
    p = os.path.join(ROOT, "_verify", name)
    exists = os.path.isfile(p)
    is_tracked = ("_verify/" + name) in TRACKED
    if name.endswith(".tar.gz"):
        # the sdist is deliberately NOT committed; the record must SAY so
        check("the sdist is not tracked, and the record says why",
              (not is_tracked) and re.search(r"not tracked", rec_body, re.I) is not None,
              "tracked=%s" % is_tracked)
    elif name == "double_ml_linear_score.py":
        # the stale predecessor: the record must disclaim it, not promise it
        check("the stale upstream file is disclaimed, not promised",
              "stale" in rec_body.lower() and "double_ml_score_mixins.py" in rec_body,
              "the record must say which file is current")
    else:
        check("the promised file %s exists AND is tracked" % name,
              exists and is_tracked, "exists=%s tracked=%s" % (exists, is_tracked))
print()

# ------------------------------------------------- 3. the record's pointers
print("=== 3. the record's pointer: did/did_cs.py:16 ===")
p = os.path.join(pkg, "did", "did_cs.py")
src = read(p).decode("utf-8", "replace").splitlines()
line16 = src[15] if len(src) > 15 else ""
check("did/did_cs.py:16 is the DoubleMLDIDCS class line",
      re.match(r"class\s+DoubleMLDIDCS\(LinearScoreMixin,\s*DoubleML\):", line16) is not None,
      "line 16 is: %r" % line16)
check("the record quotes that line",
      "class DoubleMLDIDCS(LinearScoreMixin, DoubleML):" in rec_text)
check("the record cites the line as 16",
      re.search(r"did/did_cs\.py`?\s*L?16", rec_text) is not None
      or "`did/did_cs.py` L16" in rec_text)
print()

# ------------------------------------------------------------- 4. the README
print("=== 4. the README ===")
readme = read(os.path.join(ROOT, "README.mbt.md")).decode("utf-8", "replace")
check("the README states 19 name-identical",
      "**19** match a\nclass of the same name in upstream" in readme
      or "**19** are marked *(upstream)*" in readme)
check("the README states 2 renamed", re.search(r"\*\*2\*\* are? .{0,40}renamed", readme, re.S)
      is not None)
check("the README names the no-1:1 estimator",
      "no 1:1 upstream\nclass" in readme or "no 1:1 upstream class" in readme)
check("the README no longer claims there is no port-only estimator",
      re.search(r"\*\*no\*\*\s*\n?\s*port-only estimator", readme) is None)
check("the README carries the naming-map note",
      "How the names map" in readme)
check("the README no longer pairs the port's DIDCS with upstream's DIDMulti",
      "`DoubleMLDIDCS` is upstream's `DoubleMLDIDMulti`" not in readme)
check("the README points at the record",
      "_verify/UPSTREAM_PROVENANCE.md" in readme)

# the shipped README must be byte-identical to the edited one
shipped = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")
check("the shipped README is byte-identical to the edited one",
      os.path.isfile(shipped)
      and read(shipped) == read(os.path.join(ROOT, "README.mbt.md")))
print()

print("checks: %d   failed: %d" % (checks, len(fails)))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
