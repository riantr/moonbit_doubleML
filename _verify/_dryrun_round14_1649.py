"""Round-14 dry-run: run the round-14 verifier against the PREVIOUS release.

A verifier that passes on the tree it was written for proves nothing.  This
clones the repository locally, checks out v0.164.8, and runs the SAME
verifier against it.

The defects this round fixed were all present in v0.164.8, so the verifier
must FAIL there -- and the failure count is the evidence that the checks
bite rather than merely agreeing with the text they were written beside.

The shadow is a real clone, not a `git archive` export, because the
verifier reads history: the introducing commit of each record, the
`kfold.mbt` revision at v0.52.0, and whether each path is tracked.
"""
import io
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "_verify", "_dryrun1649")
SHADOW = os.path.join(BASE, "v01648")
VERIFIER = os.path.join(ROOT, "_verify", "_verify_round14_upstream_1649.py")
OLD = sys.argv[1] if len(sys.argv) > 1 else "v0.164.8"

if os.path.isdir(SHADOW):
    shutil.rmtree(SHADOW)
os.makedirs(BASE, exist_ok=True)

# --local + --shared keeps the clone cheap; the objects live in the source
# repo, which is present for the whole run.
r = subprocess.run(["git", "clone", "--local", "--shared", "--no-checkout",
                    ROOT, SHADOW], capture_output=True, text=True)
if r.returncode != 0:
    print("clone failed:", r.stderr)
    sys.exit(2)
r = subprocess.run(["git", "-C", SHADOW, "checkout", "--detach", OLD],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("checkout failed:", r.stderr)
    sys.exit(2)
print("shadow tree: %s at %s" % (OLD, SHADOW))
print("=" * 78)

env = dict(os.environ, ROUND14_ROOT=SHADOW)
p = subprocess.run([sys.executable, VERIFIER], cwd=ROOT, env=env,
                   capture_output=True, text=True, encoding="utf-8",
                   errors="replace", timeout=1800)
out = (p.stdout or "") + (p.stderr or "")

dest = os.path.join(BASE, "dryrun.out")
with io.open(dest, "w", encoding="utf-8", errors="replace") as f:
    f.write(out)

# Count the failure lines EXACTLY.  "  FAIL" also matches the summary's
# "  FAILED:" and would double the count.
fails = [l for l in out.splitlines() if l.startswith("  FAIL  ")]
summary = [l for l in out.splitlines() if l.startswith("checks: ")]

print()
print("dry-run against %s: %s" % (OLD, " ".join(summary) or "(no summary)"))
print("  FAIL  lines: %d" % len(fails))
print()
for l in fails:
    print(l)
print()
if not fails:
    print("DRY-RUN FAILED: the verifier passes on the OLD release, so its")
    print("checks do not bite. Do not trust its PASS on the new tree.")
    sys.exit(1)
print("dry-run OK: the verifier fails on %s, so its PASS on the new tree" % OLD)
print("means something.")
sys.exit(0)
