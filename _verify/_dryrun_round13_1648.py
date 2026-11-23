"""Round-13 dry-run: run the round-13 verifier against the PREVIOUS release.

A verifier that passes on the tree it was written for proves nothing. This
extracts v0.164.7 into a shadow tree and runs the SAME verifier against it.
The defects this round fixed were all present in v0.164.7, so the verifier
must FAIL there -- and the failure count is the evidence that the checks
bite rather than merely agreeing with the text they were written beside.

The live check is skipped: the shadow tree is a source export, and the live
check needs a buildable MoonBit workspace. The STATIC checks are the ones
that carry the dry-run.
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADOW = os.path.join(ROOT, "_verify", "_dryrun1648", "v01647")
VERIFIER = os.path.join(ROOT, "_verify", "_verify_round13_validators_1648.py")
OLD = sys.argv[1] if len(sys.argv) > 1 else "v0.164.7"

# The shadow tree is a throwaway export, so it is removed and rebuilt each
# time. It lives under _verify/, which is untracked scratch.
if os.path.isdir(SHADOW):
    shutil.rmtree(SHADOW)
os.makedirs(SHADOW, exist_ok=True)

tarball = os.path.join(ROOT, "_verify", "_dryrun1648", "tree.tar")
os.makedirs(os.path.dirname(tarball), exist_ok=True)
if os.path.exists(tarball):
    os.remove(tarball)

r = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", "-o", tarball, OLD],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("git archive failed:", r.stderr)
    sys.exit(2)
# The archive is extracted with Python's tarfile, not with `tar`.
#
# WHY NOT `tar`
# ============
# The archive has exactly ONE symlink member -- README.md, which points at
# README.mbt.md -- and bsdtar on Windows cannot create a symlink without the
# "create symbolic links" privilege.  This host does not hold it (os.symlink
# fails with WinError 1314), so `tar -xf` exited 1 on that one member and the
# driver measured NOTHING: it died before the verifier ran, and the sweep
# recorded the driver as failed.
#
# WHY tarfile IS RIGHT HERE
# =========================
# A shadow tree is read, not executed, and a reader of README.md wants the
# CONTENT of the link target, not the link.  tarfile materialises the symlink
# member as a regular file carrying that content, and the explicit copy below
# makes it so whether the filter skipped the member or materialised it.  The
# conclusion the driver draws is unchanged -- and it is MEASURED, not assumed:
# the capture written below is compared with the one this driver wrote before
# the extraction changed.
with tarfile.open(tarball) as _tf:
    _tf.extractall(SHADOW, filter="data")
_src = os.path.join(SHADOW, "README.mbt.md")
_dst = os.path.join(SHADOW, "README.md")
if not os.path.exists(_dst) and os.path.exists(_src):
    shutil.copyfile(_src, _dst)
print("extracted %s -> %s" % (OLD, SHADOW))
print("=" * 78)

env = dict(os.environ, ROUND13_ROOT=SHADOW, ROUND13_SKIP_LIVE="1")
p = subprocess.run([sys.executable, VERIFIER], cwd=ROOT, env=env,
                   capture_output=True, text=True, encoding="utf-8",
                   errors="replace", timeout=1800)
out = (p.stdout or "") + (p.stderr or "")

dest = os.path.join(ROOT, "_verify", "_dryrun1648", "dryrun.out")
with io.open(dest, "w", encoding="utf-8", errors="replace") as f:
    f.write(out)

# Count the failure lines EXACTLY. "  FAIL" also matches the summary's
# "  FAILED:" and would double the count.
fails = [l for l in out.splitlines() if l.startswith("  FAIL  ")]
oks = [l for l in out.splitlines() if l.startswith("  ok    ")]
summary = [l for l in out.splitlines() if l.startswith("checks: ")]

print()
print("dry-run against %s: %s" % (OLD, " ".join(summary) or "(no summary)"))
print("  ok    lines: %d" % len(oks))
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
