"""Push master to gitee with a retry loop.

No `-u`: that rewrites the upstream pointer and would break the daily
gitee/github split. Retry because the network here is intermittent.
"""

import subprocess
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE = "origin"
BRANCH = "master"
ATTEMPTS = 6


def main():
    for i in range(1, ATTEMPTS + 1):
        p = subprocess.run(
            ["git", "push", REMOTE, BRANCH],
            cwd=REPO, capture_output=True, text=True,
            encoding="utf-8", errors="replace",
        )
        out = ((p.stdout or "") + (p.stderr or "")).strip()
        print("attempt %d exit=%d\n%s" % (i, p.returncode, out))
        if p.returncode == 0:
            return 0
        if i < ATTEMPTS:
            time.sleep(i * 5)
    return 1


if __name__ == "__main__":
    sys.exit(main())
