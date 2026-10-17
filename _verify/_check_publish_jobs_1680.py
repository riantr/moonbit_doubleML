"""Pull the per-step conclusions for the v0.163.1 runs.

`/actions/runs` gives status per run; `/actions/runs/<id>/jobs` gives status
per STEP, which is the only place the failing command is named. Filtering
hard -- the raw payload is large and the context is not.
"""

import json
import os
import sys
import urllib.request

OWNER = "riantr"
NAME = "moonbit_doubleML"
TAG = "v0.163.1"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
BASE = "https://api.github.com/repos/%s/%s" % (OWNER, NAME)


def get(url):
    req = urllib.request.Request(url)
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    runs = get(BASE + "/actions/runs?per_page=15").get("workflow_runs", [])
    targets = [r for r in runs
               if r.get("head_branch") == TAG or r.get("head_branch") == "master"]
    seen = set()
    for run in targets[:3]:
        rid = run.get("id")
        if rid in seen:
            continue
        seen.add(rid)
        print("=== %s | %s | %s | %s ==="
              % (run.get("name"), run.get("head_branch"),
                 run.get("status"), run.get("conclusion")))
        try:
            jobs = get(BASE + "/actions/runs/%d/jobs" % rid).get("jobs", [])
        except Exception as e:  # noqa: BLE001
            print("   jobs unavailable:", e)
            continue
        for job in jobs:
            print("  JOB %-40s %s" % ((job.get("name") or "")[:40], job.get("conclusion")))
            for step in job.get("steps", []):
                c = step.get("conclusion")
                mark = "  " if c in ("success", "skipped", None) else ">>"
                print("    %s %-46s %s" % (mark, (step.get("name") or "")[:46], c))
        print()


if __name__ == "__main__":
    main()
