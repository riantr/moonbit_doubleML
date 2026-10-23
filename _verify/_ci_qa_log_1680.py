"""Fetch the CI QA-loop job log and name the check that failed.

`/actions/runs` and `/actions/runs/<id>/jobs` both report the step verdict
but never the check name -- that lives only in the log, as
`::error::QA loop FAILED: <ids>`. Job logs come back as a zip, so this
downloads, extracts, and prints only the lines around the failure rather
than the whole log.
"""

import io
import json
import os
import sys
import urllib.request
import zipfile

OWNER = "riantr"
NAME = "moonbit_doubleML"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
BASE = "https://api.github.com/repos/%s/%s" % (OWNER, NAME)
WANT_SHA = sys.argv[1] if len(sys.argv) > 1 else "67e1e64"


def get(url, raw=False):
    req = urllib.request.Request(url)
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    return data if raw else json.loads(data.decode("utf-8"))


def main():
    runs = get(BASE + "/actions/runs?per_page=15").get("workflow_runs", [])
    target = None
    for r in runs:
        if (r.get("name") == "CI"
                and (r.get("head_sha") or "").startswith(WANT_SHA)):
            target = r
            break
    if target is None:
        print("no CI run for %s; available:" % WANT_SHA)
        for r in runs[:8]:
            print("  %-6s %-34s %s" % ((r.get("head_sha") or "")[:6],
                                      r.get("name"), r.get("head_branch")))
        return 3
    print("run:", target.get("id"), target.get("status"), target.get("conclusion"))

    jobs = get(BASE + "/actions/runs/%d/jobs" % target["id"]).get("jobs", [])
    qa = [j for j in jobs if j.get("conclusion") == "failure"]
    for j in qa:
        print("failed job:", j.get("name"), "id", j.get("id"))
        blob = get(BASE + "/actions/jobs/%d/logs" % j["id"], raw=True)
        import tempfile
        tmp = tempfile.mkdtemp(prefix="gha_log_")
        zp = os.path.join(tmp, "l.zip")
        with open(zp, "wb") as f:
            f.write(blob)
        text = []
        with zipfile.ZipFile(zp) as zf:
            for n in zf.namelist():
                if n.endswith(".txt"):
                    text.append(zf.read(n).decode("utf-8", "replace"))
        log = "\n".join(text)
        outp = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "_verify", "_ci_qa_log_1680.txt")
        with io.open(outp, "w", encoding="utf-8", newline="\n") as f:
            f.write(log)
        print("full log ->", outp, "(%d lines)" % len(log.split("\n")))
        lines = log.split("\n")
        for i, l in enumerate(lines):
            if "QA loop FAILED" in l or "::error::" in l:
                print("---")
                for k in range(max(0, i - 4), min(len(lines), i + 3)):
                    print("   ", lines[k].rstrip()[:150])
    return 0


if __name__ == "__main__":
    main()
