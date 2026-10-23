"""Finish the 0.163.1 release: the two version references the first pass missed.

Both were found by the repo's own gates, not by inspection, and both are the
same class of omission: a version bump has to land in FOUR places, and the
first pass only did two of them.

1. The SHIPPED README. `moon.mod` sits in `moonbit_doubleML/` and says
   `readme = "README.mbt.md"`, which resolves RELATIVE TO THE PACKAGE DIR.
   So `moonbit_doubleML/README.mbt.md` is what `moon publish` sends to
   mooncakes.io and what the registry page renders -- the root README is the
   one humans edit and GitHub shows. `.github/scripts/check_readme_sync.py`
   requires them byte-identical and says which way to copy. It failed at
   line 33. The first pass edited only the root copy.

2. The api_server's advertised version. `examples/api_server/main.mbt`
   hardcodes `riantr/moonbit_doubleML@<version>` in `/version`, and the
   qa_loop `api_test` check GETs that endpoint and compares it against the
   real moon.mod. Its own comment records this drifting twice already -- to
   0.52.0, then to 0.162.0 on the last bump. It drifted a third time on this
   one.

Writes the SHIPPED readme as a byte copy of the edited one rather than
re-applying edits, because the guard's contract is byte-identity and a
re-spliced copy is how the two diverged in the first place.
"""

import io
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD_V, NEW_V = "0.163.0", "0.163.1"

EDITED = os.path.join(REPO, "README.mbt.md")
SHIPPED = os.path.join(REPO, "moonbit_doubleML", "README.mbt.md")
API = os.path.join(REPO, "examples", "api_server", "main.mbt")

API_OLD = 'library: "riantr/moonbit_doubleML@%s",' % OLD_V
API_NEW = 'library: "riantr/moonbit_doubleML@%s",' % NEW_V


def read(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def write(p, t, eol="\n"):
    with io.open(p, "w", encoding="utf-8", newline=eol) as f:
        f.write(t)


def main():
    # ---- 1. api_server advertised version --------------------------------
    a = read(API)
    if "\r" in a:
        raise SystemExit("api_server/main.mbt is not LF-only")
    n = a.count(API_OLD)
    if n != 1:
        raise SystemExit("api version literal matched %d times" % n)
    a = a.replace(API_OLD, API_NEW)
    # The comment above it records the history of this literal drifting; add
    # this occurrence so the next bump does not read it as a solved problem.
    marker = "  // all 24 cross-checks.\n"
    if a.count(marker) != 1:
        raise SystemExit("api comment anchor matched %d times" % a.count(marker))
    addition = (
        "  //\n"
        "  // It drifted a THIRD time, to %s, on the %s bump. The first pass\n"
        "  // edited the root README and moon.mod and stopped; `readme-sync`\n"
        "  // caught the shipped copy and `api_test` caught this literal, in the\n"
        "  // same run. Both are real gates doing their job -- a version bump\n"
        "  // touches FOUR places: moon.mod, the edited README, the shipped\n"
        "  // README copy, and this literal.\n"
    ) % (OLD_V, NEW_V)
    a = a.replace(marker, marker + addition)
    write(API, a)

    # ---- 2. shipped README = byte copy of the edited one -----------------
    shutil.copyfile(EDITED, SHIPPED)

    # ---- verify ----------------------------------------------------------
    e, s = read(EDITED), read(SHIPPED)
    a2 = read(API)
    print("api literal bumped  :", API_NEW in a2, "| old gone:", API_OLD not in a2)
    print("README byte-identical:", e == s)
    print("shipped has small-n  :", "Known divergence, reported and NOT gated" in s)
    print("shipped version line :",
          [l for l in s.split("\n") if l.startswith("| `moon.mod` version")])
    print("shipped test lines   :", [l for l in s.split("\n") if l.startswith("| Tests")])
    print("shipped release-tag  :", "--release-tag v%s" % NEW_V in s)
    print("stale %s left in shipped: %s" % (OLD_V, OLD_V in s))
    print("api_server BOM/CR    :", a2.startswith("\ufeff"), "\r" in a2)

    # ---- run both gates --------------------------------------------------
    for label, cmd in (
        ("readme-sync", [sys.executable, os.path.join(REPO, ".github", "scripts",
                                                      "check_readme_sync.py")]),
        ("api_test", [sys.executable, os.path.join(REPO, ".github", "scripts",
                                                   "qa_loop", "run.py"),
                      "--full", "--only", "api_test", "--allow-inert"]),
    ):
        r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = ((r.stdout or "") + (r.stderr or "")).strip().splitlines()
        print("--- %s exit=%d ---" % (label, r.returncode))
        for line in out[-6:]:
            print("   ", line)


if __name__ == "__main__":
    main()
