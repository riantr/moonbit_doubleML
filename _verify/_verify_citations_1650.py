#!/usr/bin/env python3
"""Round 39 verifier: the README's LITERATURE CITATIONS.

WHAT THIS PROVES
=================
A citation is a claim about the world, and no in-tree check could see one --
which is how a wrong page range survived thirty-eight rounds.  The README
cited

    That is the honesty of Athey & Imbens (2016, PNAS 113(27):7353-7358)

while the publisher's own deposited record for the DOI gives the page range
as 7353-7360.  The authors, the year, the journal, the volume and the issue
were all right, and the SUBSTANCE the README credits is right -- only the
last two digits of the range were wrong.  A reader who looked the paper up
would have found the citation wrong and the claim right, which is the worst
of both.

So this checks each citation against the PUBLISHER's record, field by field:
the year, the volume, the issue, and the page range.  A citation the README
drops or rewrites into an unreadable shape FAILS -- the shape is part of
what the reader reads.

WHAT IS NOT CHECKED, AND WHY
============================
That the README's CHARACTERISATION of each paper is right.  "Athey &
Imbens define honesty as ..." is a claim about an argument, and the
publisher's metadata does not carry arguments.  The one characterisation the
README leans on -- the honesty property -- is checked where it CAN be: the
source's own implementation of the honesty split, in `_verify/`'s records.

THE NETWORK
===========
Crossref and arXiv are consulted over HTTPS.  When they cannot be reached,
this SKIPS with a reason -- still counted, still visible -- rather than
failing: an unreachable publisher is not a wrong citation, and a contract
that turns a network outage into a red build teaches its reader to ignore
it.  (The round-23 precedent: a rule with false positives teaches its reader
to ignore it.)

THE CHECK COUNT IS FIXED AT 11
=============================
The count this verifier publishes is 11, and it is 11 in EVERY network
condition.  That is not automatic: a skip that stands in for SEVERAL checks
would make the count move, and it did.  When arXiv was unreachable the
preprint's two checks collapsed into ONE skip, so the run reported 10
instead of 11 -- and the check that owns the banner's published counts
(`_verify/_verify_ledger_counts_1650.py`) compares the banner's number with
the number this run MAKES, so the whole tracked contract turned red on a
publisher's rate limit.  Two independent fresh-eyes audits reproduced it,
one of them by watching arXiv answer 429.

So a skip now stands for EXACTLY the check it replaces: one skip per field
that could not be compared, and one per arXiv check.  The count is the
number of checks DEFINED, which is a property of this file and not of the
network.  This is the round-29 precedent -- the docstring-count verifier's
count is fixed, not tree-dependent -- applied to the network.

Run: python _verify/_verify_citations_1650.py
"""
import io
import json
import os
import re
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
README = os.path.join(ROOT, "README.mbt.md")

NCHECK = 0
FAILS = []
SKIPPED = []


def check(label, ok, detail=""):
    global NCHECK
    NCHECK += 1
    print("  %-62s %s" % ("ok" if ok else "*** FAIL ***", label))
    if not ok:
        FAILS.append("%s -- %s" % (label, detail))
        print("      %s" % detail)


def skip(label, reason):
    global NCHECK
    NCHECK += 1
    print("  SKIP  %-62s %s" % (label, reason))
    SKIPPED.append((label, reason))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


def flat(s):
    return re.sub(r"\s+", " ", s)


def fetch(url, timeout=30):
    """Return (ok, payload).  `payload` is the decoded body on success and
    the reason on failure -- the caller decides what a failure means."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "moonbit_doubleML-verify/1.0 (repository citation check)"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, r.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return False, "%s: %s" % (type(e).__name__, e)


readme = flat(read(README))

# The citation table.  The README's own shape is the regex; the DOI is the
# publisher's own identifier for the work it names.
CITATIONS = [
    {
        "label": "Athey & Imbens (PNAS)",
        "regex": r"Athey & Imbens \((\d{4}), PNAS (\d+)\((\d+)\):(\d+)-(\d+)\)",
        "doi": "10.1073/pnas.1510489113",
        "url": "https://api.crossref.org/works/10.1073/pnas.1510489113",
        "fields": ("year", "volume", "issue", "page_first", "page_last"),
    },
    {
        "label": "Wager & Athey (JASA)",
        "regex": r"Wager & Athey \((\d{4}), JASA\)",
        "doi": "10.1080/01621459.2017.1319839",
        "url": "https://api.crossref.org/works/10.1080/01621459.2017.1319839",
        "fields": ("year",),
    },
]

print()
print("A. the journal citations, against the publisher's record")

for c in CITATIONS:
    m = re.search(c["regex"], readme)
    if not m:
        check("the README cites %s in a readable form" % c["label"], False,
              "the citation shape %r is not in the README" % c["regex"])
        continue
    check("the README cites %s in a readable form" % c["label"], True)
    stated = {"year": m.group(1), "volume": m.group(2) if len(m.groups()) > 1 else None,
              "issue": m.group(3) if len(m.groups()) > 2 else None,
              "page_first": m.group(4) if len(m.groups()) > 3 else None,
              "page_last": m.group(5) if len(m.groups()) > 4 else None}

    ok, payload = fetch(c["url"])
    if not ok:
        # One skip PER FIELD: the online path below makes one check per
        # field, so a single skip standing in for all of them would move the
        # check count with the network.  See THE CHECK COUNT IS FIXED AT 11.
        for f in c["fields"]:
            skip("the %s citation's %s matches the publisher's record"
                 % (c["label"], f),
                 "the publisher is unreachable (%s)" % payload)
        continue
    try:
        doc = json.loads(payload)["message"]
    except Exception as e:  # noqa: BLE001
        for f in c["fields"]:
            skip("the %s citation's %s matches the publisher's record"
                 % (c["label"], f),
                 "the publisher's record could not be parsed (%s)" % e)
        continue

    parts = (doc.get("page") or "").split("-")
    publisher = {
        "year": str((doc.get("issued", {}).get("date-parts") or [[None]])[0][0]),
        "volume": doc.get("volume"),
        "issue": doc.get("issue"),
        "page_first": parts[0] if parts else None,
        "page_last": parts[1] if len(parts) > 1 else parts[0] if parts else None,
    }
    print("   %-22s README %s" % (c["label"],
                                  {k: stated[k] for k in c["fields"]}))
    print("   %-22s DOI    %s" % ("", {k: publisher[k] for k in c["fields"]}))
    for f in c["fields"]:
        check("the %s citation's %s matches the publisher's record"
              % (c["label"], f),
              stated[f] is not None and stated[f] == publisher[f],
              "README %r vs publisher %r" % (stated[f], publisher[f]))

print()
print("B. the preprint citation")

m = re.search(r"Cattaneo, Klusowski & Yu \(arXiv:(\d+\.\d+)\)", readme)
if not m:
    check("the README cites the preprint in a readable form", False,
          "the arXiv citation is not in the README")
else:
    check("the README cites the preprint in a readable form", True)
    aid = m.group(1)
    ok, payload = fetch("https://export.arxiv.org/api/query?id_list=%s" % aid)
    if not ok:
        # TWO skips: the online path below makes two checks, so the count
        # must not shrink when arXiv is unreachable.  See THE CHECK COUNT IS
        # FIXED AT 11.
        skip("the preprint %s resolves to an arXiv record" % aid,
             "arXiv is unreachable (%s)" % payload)
        skip("the preprint record carries a title",
             "arXiv is unreachable (%s)" % payload)
    else:
        got = re.search(r"<id>http://arxiv\.org/abs/([^<]+)</id>", payload)
        title = re.search(r"<title>(.*?)</title>", payload, re.S)
        # arXiv answers with the VERSIONED id ("2509.11381v3"), and the README
        # cites the bare id.  Strip the version suffix before comparing --
        # splitting on "v" would cut the id itself, because the id's own
        # digits come after a "v" only in the suffix.
        got_id = re.sub(r"v\d+$", "", got.group(1)) if got else None
        check("the preprint %s resolves to an arXiv record" % aid,
              got_id == aid, "arXiv returned %r" % (got_id,))
        check("the preprint record carries a title",
              title is not None and len(title.group(1).strip()) > 10,
              "no title in the feed")

print()
print("=" * 74)
print("%d checks, %d failed, %d skipped" % (NCHECK, len(FAILS), len(SKIPPED)))
if FAILS:
    print("*** FAIL ***")
    for f in FAILS:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
