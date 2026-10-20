"""Which _verify/*.md records still carry NO re-audit banner?

A record that has been re-audited in some round opens with a dated banner: a
blockquote that names the commit that introduced it, what has changed since,
and what is NOT verified.  Records without one are the unaudited remainder.

The banner is a BLOCKQUOTE at the top of the file.  A record whose body
mentions a banner-ish phrase is not thereby audited -- the check is on the
STRUCTURE: a line starting with '>' near the top.
"""
import glob
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
VD = os.path.join(REPO, "_verify")

files = sorted(glob.glob(os.path.join(VD, "*.md")))
print("_verify/*.md records on disk: %d\n" % len(files))

banner_re = re.compile(r"^\s*>\s*\S", re.M)
# The banner is the LEADING BLOCKQUOTE (after the title), and a record counts
# as re-audited only if the banner names the re-audit AND the body states
# what is NOT verified.  An earlier version of this file looked for the
# literal phrase "what has changed since", which the round-15 records express
# as a pointer table instead -- so it mis-sorted them as unaudited.  A census
# that is wrong about its own subject is worse than no census.
has_commit = re.compile(r"\b[0-9a-f]{7}\b")
re_audited = re.compile(r"\*\*Re-audited\b|Historical record", re.I)
has_not_verified = re.compile(r"not verified", re.I)

audited, unaudited, partial = [], [], []
for path in files:
    name = os.path.basename(path)
    raw = open(path, "rb").read()
    text = raw.decode("utf-8", errors="replace")
    head = "\n".join(text.splitlines()[:40])
    is_banner = bool(banner_re.search(head)) and re_audited.search(head) is not None
    if is_banner and has_not_verified.search(text):
        audited.append(name)
    elif is_banner:
        partial.append(name)
    else:
        unaudited.append(name)

print("AUDITED (leading blockquote naming a re-audit + a 'not verified' statement): %d"
      % len(audited))
for n in audited:
    print("   " + n)
print()
print("PARTIAL (a blockquote up top, but not the full banner shape): %d" % len(partial))
for n in partial:
    print("   " + n)
print()
print("UNAUDITED (no banner at all): %d" % len(unaudited))
for n in unaudited:
    size = os.path.getsize(os.path.join(VD, n))
    print("   %-46s %6d bytes" % (n, size))
