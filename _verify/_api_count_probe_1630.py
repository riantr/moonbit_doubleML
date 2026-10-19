"""How many sequential requests does api_server survive?

Settle with NO requests at all (25s), then send 10 sequential GETs, reporting
status and liveness after each. No readiness polling, so nothing competes
with the measurement.
"""
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".github", "scripts", "qa_loop"))
import checks as C

proc = subprocess.Popen(["moon", "run", "--target", "native", "examples/api_server"],
                        cwd=C.ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, encoding="utf-8", errors="replace")
try:
    time.sleep(25)
    print("alive before any request: %s" % (proc.poll() is None))
    for i in range(1, 11):
        st, body = C._http(4000, "/healthz")
        alive = proc.poll() is None
        print("  req %2d -> %-3s alive=%-5s %s" % (i, st, alive, body[:40]))
        if not alive:
            print("  DIED after request %d (rc=%s)" % (i, proc.returncode))
            break
    else:
        print("  survived all 10 sequential requests")
finally:
    C._kill_tree(proc)
    time.sleep(1)
    try:
        out = proc.stdout.read()
    except Exception:
        out = ""
    print("--- server output ---")
    print(out[-400:])
