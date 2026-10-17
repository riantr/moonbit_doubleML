"""Confirm github CI picked up the v0.163.1 tag push.

Filters hard on purpose: a bare `GET /actions/runs` returns megabytes of JSON
and would swamp the context, and the interesting part is only a handful of
fields per run.
"""

import json
import os
import sys
import urllib.request

REPO_OWNER = "riantr"
REPO_NAME = "moonbit_doubleML"
TAG = "v0.163.1"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

url = ("https://api.github.com/repos/%s/%s/actions/runs?per_page=15"
       % (REPO_OWNER, REPO_NAME))
req = urllib.request.Request(url)
if TOKEN:
    req.add_header("Authorization", "Bearer " + TOKEN)
req.add_header("Accept", "application/vnd.github+json")

try:
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read().decode("utf-8"))
except Exception as e:  # noqa: BLE001
    print("could not query: %s" % e)
    sys.exit(3)

runs = data.get("workflow_runs", [])
print("total runs returned:", len(runs))
print()
print("%-34s %-9s %-11s %s" % ("name", "event", "head_branch", "conclusion"))
found = False
for run in runs:
    name = (run.get("name") or "")[:34]
    ev = run.get("event") or ""
    br = run.get("head_branch") or ""
    cc = run.get("conclusion") or run.get("status") or ""
    if TAG in br or TAG in (run.get("head_sha") or "")[:0] or "publish" in name.lower():
        found = True
    print("%-34s %-9s %-11s %s" % (name, ev, br[:11], cc))
print()
tagged = [r for r in runs if r.get("head_branch") == TAG]
print("runs whose head_branch == %s: %d" % (TAG, len(tagged)))
for r in tagged:
    print("   %s | %s | %s" % (r.get("name"), r.get("status"),
                               r.get("conclusion")))
