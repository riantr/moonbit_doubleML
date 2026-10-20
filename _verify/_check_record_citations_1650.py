"""Do the shipped records (or the README) cite any _verify/*.md that is NOT
tracked?  A path in prose is a promise, and an untracked file is a promise a
reader cannot keep.
"""
import glob
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
tracked = set(subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True,
                             text=True, encoding="utf-8", errors="replace"
                             ).stdout.splitlines())
tracked = {t.replace("\\", "/") for t in tracked}

SIX = ["PORT_VS_UPSTREAM_DEFAULTS_1540.md", "LEARNER_DEFAULTS_1530.md",
       "N_FOLDS_1570.md", "IN_SAMPLE_NORMALIZATION_1570.md",
       "SCORE_VOCABULARY_1550.md", "PARITY_COMMENTS_1570.md",
       "N_FOLDS_INNER_1550.md"]

targets = [("README.mbt.md", os.path.join(REPO, "README.mbt.md"))]
for r in SIX:
    targets.append((r, os.path.join(REPO, "_verify", r)))

pat = re.compile(r"_verify/([A-Za-z0-9_./-]+\.md)")
bad = []
for label, path in targets:
    text = open(path, encoding="utf-8", errors="replace").read()
    for m in pat.findall(text):
        if ("_verify/" + m) not in tracked:
            bad.append((label, m))

print("=== citations of UNTRACKED _verify/*.md from the shipped README and records ===")
if not bad:
    print("  (none)")
for label, m in bad:
    print("  %-34s -> _verify/%s" % (label, m))
print()

print("=== all _verify/*.md cited by the README, tracked or not ===")
readme = open(os.path.join(REPO, "README.mbt.md"), encoding="utf-8", errors="replace").read()
for m in sorted(set(pat.findall(readme))):
    print("  %-44s %s" % (m, "tracked" if ("_verify/" + m) in tracked else "UNTRACKED"))
print()

print("=== the substantive untracked records (not _changelog fragments) ===")
untracked_md = []
for p in sorted(glob.glob(os.path.join(REPO, "_verify", "*.md"))):
    rel = os.path.relpath(p, REPO).replace("\\", "/")
    if rel not in tracked:
        untracked_md.append(rel)
subst = [m for m in untracked_md if not os.path.basename(m).startswith("_changelog")
         and not os.path.basename(m).startswith("_chlog")]
for m in subst:
    print("  %-44s %7d bytes" % (m, os.path.getsize(os.path.join(REPO, m))))
print("  (%d untracked records, %d of them non-changelog-fragment)"
      % (len(untracked_md), len(subst)))
