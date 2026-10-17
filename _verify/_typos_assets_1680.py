"""List the typos v1.19.0 release assets so the right Windows build can be used.

The workflow downloads `typos-v1.19.0-x86_64-unknown-linux-musl.tar.gz`,
which is a Linux ELF and cannot execute on Windows (WinError 216). The
DICTIONARY is what matters, not the target triple, so any build of the SAME
version reproduces the gate -- but it has to be a Windows build.
"""

import json
import sys
import urllib.request

URL = "https://api.github.com/repos/crate-ci/typos/releases/tags/v1.19.0"

try:
    with urllib.request.urlopen(URL, timeout=60) as r:
        data = json.loads(r.read().decode("utf-8"))
except Exception as e:  # noqa: BLE001
    print("could not list assets:", e)
    sys.exit(3)

for a in data.get("assets", []):
    print("%-70s %8d" % (a.get("name"), a.get("size")))
