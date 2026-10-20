"""How the dry-run's witness commit was chosen.

The test-count verifier asserts an INVARIANT -- "the number the README
states is the number the tree has".  To prove such a verifier bites, it has
to be run against a tree where the invariant is FALSE.  This finds those
trees.

Method: for every commit that touched the package or the README, count the
`test "..."` declarations in the package (static enumeration) and read the
count the README states (its Status table).  Report the commits where the
two differ.

The result is the reason the witness is a witness and not a convenient
example: the divergence is RECURRENT, not a one-off.  At the time of
writing, 84 of the 234 commits examined disagreed -- including six commits
from the LPLR work, where a test was added and the README's count was not
carried with it.

Run: python _verify/_r19_find_diverge_1650.py
"""
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROW = re.compile(r"\| Tests \(native / wasm / js\) \| \*\*(\d+)")


def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=ROOT, capture_output=True)
    return r.returncode, r.stdout.decode("utf-8", "replace")


def lib_count(ref):
    _, out = git("grep", "-h", "-o", "-E", r'\btest\s+"', ref,
                 "--", "moonbit_doubleML/*.mbt")
    return out.count("\n")


def readme_count(ref):
    _, out = git("show", "%s:README.mbt.md" % ref)
    m = ROW.search(out)
    return int(m.group(1)) if m else None


# the commits that could have changed either side
_, log = git("log", "--format=%H %s", "-n", "400", "--",
             "moonbit_doubleML", "README.mbt.md")
commits = [l.split(" ", 1)[0] for l in log.splitlines() if l.strip()]

bad = []
for c in commits:
    lc = lib_count(c)
    rc = readme_count(c)
    if rc is None:
        continue
    if rc != lc:
        bad.append((c, rc, lc))

print("commits examined: %d" % len(commits))
print("commits where the README's count != the tree's count: %d" % len(bad))
for c, rc, lc in bad[:12]:
    _, subj = git("log", "-1", "--format=%s", c)
    print("  %s  README says %d, tree has %d   %s" % (c[:9], rc, lc, subj[:70]))
