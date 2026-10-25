"""Classify the 21 example packages: which are drivers, which are fixtures?

The Project-layout section says "examples/  <- 21 driver binaries", and the
Examples table labels two of them "fixture" (`examples/bitexact`,
`examples/parity`). Those two statements cannot both be right.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EX = os.path.join(ROOT, "examples")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

pkgs = sorted(d for d in os.listdir(EX)
              if os.path.isfile(os.path.join(EX, d, "moon.mod")))
print("example packages: %d" % len(pkgs))
print("")

has_main, no_main, has_readme = [], [], []
for p in pkgs:
    d = os.path.join(EX, p)
    mains = [f for f in os.listdir(d) if f.endswith(".mbt")
             and re.search(r"\bfn\s+main\b", io.open(os.path.join(d, f),
                                                     encoding="utf-8",
                                                     errors="replace").read())]
    (has_main if mains else no_main).append(p)
    if os.path.isfile(os.path.join(d, "README.md")):
        has_readme.append(p)

print("with a `fn main` (%d): %s" % (len(has_main), ", ".join(has_main)))
print("")
print("without a `fn main` (%d): %s" % (len(no_main), ", ".join(no_main)))
print("")
print("with a README.md (%d): %s" % (len(has_readme), ", ".join(has_readme)))
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# the Examples table labels two of them "fixture"
table_rows = re.findall(r"^\|\s*`examples/([a-z_]+)`\s*\|\s*([^|]+?)\s*\|", readme, re.M)
fixtures = [n for n, model in table_rows if model.strip() == "fixture"]
print("Examples table rows: %d, of which labelled 'fixture': %s"
      % (len(table_rows), fixtures))

check("the layout says '21 driver binaries'", "21 driver binaries" in readme)

# --------------------------------------------------------------------------- #
# HOW MANY ARE CLI-STYLE NUMERIC DEMOS
# --------------------------------------------------------------------------- #
# The Examples section says "21 `examples/<bin>/` directories in `moon.work`.
# 16 are CLI-style numeric demos that print an estimate".  The 21 was derived
# from moon.work; the 16 was a FLOATING NUMBER -- the round-46 audit mutated
# it to 15 and every check in the tree stayed GREEN.
#
# So the 16 is derived too: the example packages in moon.work MINUS the ones
# that are not CLI-style numeric demos.  The list of non-CLI packages is
# small and explicit, and its COMPLETENESS is enforced by the equality below
# -- if the tree gains an example, the equality fails and this file says so.
#
# The other half of the claim -- that the list the CLI verifier RUNS is this
# set -- is owned by `_verify/_verify_cli_demo_ci_1650.py`, which runs them.
NOT_CLI = ["api_server", "bitexact", "consumer_demo", "fuzz", "parity"]
work = io.open(os.path.join(ROOT, "moon.work"), encoding="utf-8").read()
example_pkgs = re.findall(r'"(examples/[a-z_]+)"', work)
cli_from_tree = sorted(p.split("/", 1)[1] for p in example_pkgs
                       if p.split("/", 1)[1] not in NOT_CLI)
doc = re.sub(r"\s+", " ", readme)
check("moon.work lists 21 example packages",
      len(example_pkgs) == 21, "got %d" % len(example_pkgs))
check("the CLI-style demos are the example packages minus the non-CLI ones",
      len(cli_from_tree) == 16, "got %d: %s" % (len(cli_from_tree), cli_from_tree))
check("the README's CLI-style count is the count derived from the tree",
      ("%d are CLI-style numeric demos" % len(cli_from_tree)) in doc,
      "derived %d" % len(cli_from_tree))
check("two of the 21 are labelled fixture in the Examples table",
      len(fixtures) == 2, "got %d: %s" % (len(fixtures), fixtures))
check("all 21 packages have a `fn main`, so all 21 are binaries",
      len(has_main) == len(pkgs),
      "got %d of %d" % (len(has_main), len(pkgs)))
check("the two 'fixture' rows are still runnable programs",
      set(fixtures) <= set(has_main),
      "fixtures=%s" % fixtures)

check("examples/api_server/README.md exists",
      os.path.isfile(os.path.join(EX, "api_server", "README.md")),
      "the README points at it for the full curl recipe")
check("the README points at examples/api_server/README.md",
      "examples/api_server/README.md" in readme)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
