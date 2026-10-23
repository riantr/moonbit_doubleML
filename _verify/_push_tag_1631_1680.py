"""Push the 0.163.1 release to both remotes, with retries.

Order and retry policy follow the repo's release rules:

  gitee (origin) = daily store  -> push first
  github         = releases only -> push second; CI publishes from the tag

`MOONCAKES_RIANTR_TOKEN` is set and `publish.yml`'s `on.push.tags` is active,
so a github tag push triggers the publish. **This script never runs
`moon publish`** -- the workflow header says doing so by hand fails on an
existing version, and the release policy forbids it outright.

github's 443 is intermittent here, not blocked, so both remotes get the same
6-attempt loop with increasing sleep. Never `-u`: that would repoint the
upstream tracking and break the daily gitee push.

The tag is never deleted or moved, on failure or otherwise.
"""

import subprocess
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG = "v0.163.1"
ATTEMPTS = 6


def push(remote, refspec, label):
    for attempt in range(1, ATTEMPTS + 1):
        r = subprocess.run(["git", "push", remote, refspec], cwd=REPO,
                           capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = ((r.stdout or "") + (r.stderr or "")).strip()
        print("[%s] attempt %d exit=%d" % (label, attempt, r.returncode))
        if r.returncode == 0:
            print("    " + "\n    ".join(out.splitlines()[-3:]))
            return True
        tail = out.splitlines()[-2:] if out else []
        for t in tail:
            print("    ! " + t.strip()[:120])
        if attempt < ATTEMPTS:
            wait = attempt * 5
            print("    retrying in %ds" % wait)
            time.sleep(wait)
    print("[%s] GAVE UP after %d attempts" % (label, ATTEMPTS))
    return False


def main():
    ok = True
    ok &= push("origin", "master", "gitee master")
    ok &= push("origin", "refs/tags/%s" % TAG, "gitee tag")
    ok &= push("github", "master", "github master")
    ok &= push("github", "refs/tags/%s" % TAG, "github tag")

    print()
    for remote in ("origin", "github"):
        r = subprocess.run(["git", "ls-remote", "--tags", remote, TAG],
                           cwd=REPO, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        got = [l for l in r.stdout.splitlines() if TAG in l]
        print("%-8s tag present: %s %s" % (remote, bool(got),
                                           got[0].split()[0][:12] if got else ""))
    print()
    print("ALL PUSHES OK" if ok else "SOME PUSHES FAILED -- retry, do NOT publish locally")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
