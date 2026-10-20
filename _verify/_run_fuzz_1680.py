"""Run the fuzz surfaces and record the verdict to a file.

Filtering `moon run` output through PowerShell truncates it and swallows the
exit code (a closed pipe shows up as 4294967295). This captures everything to
UTF-8 and prints only the tail, so the verdict is read from the real log.

Run: python _verify/_run_fuzz_1680.py
"""

import io
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import FUZZ_RUN_LOG  # noqa: E402

LOG = FUZZ_RUN_LOG
TAIL = 60

cmd = ["moon", "run", "examples/fuzz", "--target", "native"]
print("running: %s" % " ".join(cmd))
r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                   encoding="utf-8", errors="replace", timeout=5400)

body = (r.stdout or "") + (("\n[stderr]\n" + r.stderr) if r.stderr else "")
with io.open(LOG, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(body)

lines = body.splitlines()
print("exit=%d   log=%s   (%d lines)" % (r.returncode, LOG, len(lines)))
print("--- tail %d ---" % TAIL)
for ln in lines[-TAIL:]:
    print(ln)

fails = [ln for ln in lines if "FAIL" in ln.upper()]
print("--- lines containing FAIL: %d ---" % len(fails))
for ln in fails[:20]:
    print(ln)
sys.exit(r.returncode)
