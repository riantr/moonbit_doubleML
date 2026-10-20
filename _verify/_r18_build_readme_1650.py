"""Round 18: build the user-facing README and the companion ENGINEERING.md.

The README that ships is the page a reader lands on.  It was 2290 lines, of
which roughly 1200 were an internal investigation narrative -- a history of
defects found and fixed in past releases, the CI harness's internals, and the
archaeology behind the upstream naming map.  None of that is something a user
of the library needs in order to use it.

So the document is split in two:

  README.mbt.md    the LIBRARY document -- what it is, how to install it, how
                   to call it, where its sharp edges are, what it does not
                   claim.  Shaped like the reference package page.
  ENGINEERING.md   the PROJECT document -- the README as it stood at
                   v0.164.11, in full, with a banner that says what it is.

THE LINE BETWEEN THEM
---------------------
A fact is in the README when a person who has run `moon add
riantr/moonbit_doubleML` and is writing code against the library would need it
to use the library correctly or to trust its output.  A fact is in
ENGINEERING.md when it describes this repository -- its CI, its QA registry, its
release history -- rather than the library.

42 verifiers pin 397 distinct strings in the README.  Every one of them is a
fact the project has established, so this rewrite KEEPS every user-facing one
IN the README, verbatim, and moves the project-facing ones to ENGINEERING.md
together with the checks that assert them.  Nothing is deleted: the ledger is
the whole previous README, word for word, and the new README is a condensation
of it.

THE SOURCE
----------
The pre-rewrite README is read from the released tag, not from a working-copy
backup, so this builder is re-runnable from any checkout:

    git cat-file blob v0.164.11:README.mbt.md

LF-only, no BOM, in and out.  The shipped copy
`moonbit_doubleML/README.mbt.md` is written byte-identically.

THE VERSION
-----------
The version comes from `moonbit_doubleML/moon.mod`, so this builder and the
bump script cannot disagree: the bump script changes `moon.mod` and then
calls this builder, and the README's version sites follow.

NOTE FOR A LATER ROUND
----------------------
This builder is PINNED to the v0.164.11 source.  Re-running it rebuilds the
README from that release, so it would revert any README edit made after
round 18.  A later round that edits the README must either update SRC_TAG
and the block ranges, or stop using this builder and edit the README
directly.  The round-18 verifier's pinned-literal census would catch such a
reversion, but the fix belongs to the round that caused it.

ROUND 20 ADDED A PATCH STEP, AND THAT IS THE MECHANISM
------------------------------------------------------
Round 20 found a gap in the API reference and fixed it here rather than in
README.mbt.md, because a direct edit would be reverted by the next bump.
The fix is a (old, new) pair applied to the assembled text, so the README is
still generated from one source and the fix travels with it.  A later round
that edits the README should add its own pair to PATCHES, not edit
README.mbt.md.

ROUND 21 ADDED A SECOND PAIR
----------------------------
Same mechanism, for a different kind of defect: two measured figures that the
measurements do not support.  The pair lives in PATCHES below, next to a
comment that carries the measurement it was derived from.  Two things follow
for whoever comes next:

  * The pair is applied to the ASSEMBLED text, so it must match exactly once.
    The builder aborts if it matches any other number of times -- that is the
    check that stops a patch from silently doing nothing.
  * A patch that changes a NUMBER is only as good as the measurement behind
    it.  The measurement is a tracked record
    (`_verify/_hazard_margins_1650.json`) and a tracked verifier
    (`_verify/_verify_hazard_margins_1650.py`) that checks the README against
    it.  A patched number with no witness is a new unverified claim.
"""
import io
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

# ------------------------------------------------------------------- the source
SRC_TAG = "v0.164.11"
BACKUP = "_r18_readme_before_1650.md"


def load_source():
    """The pre-rewrite README, from the released tag or the local backup."""
    try:
        out = subprocess.run(["git", "cat-file", "blob", "%s:README.mbt.md" % SRC_TAG],
                             cwd=ROOT, capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout, "git %s:README.mbt.md" % SRC_TAG
    except OSError:
        pass
    if os.path.exists(BACKUP):
        return io.open(BACKUP, encoding="utf-8", newline="").read(), BACKUP
    raise SystemExit("no source: neither %s:README.mbt.md nor %s"
                     % (SRC_TAG, BACKUP))


SRC, SRC_FROM = load_source()
L = SRC.split("\n")


def blk(a, b):
    """Old-README lines a..b inclusive, verbatim."""
    return "\n".join(L[a - 1:b])


def ver():
    m = re.search(r'^version\s*=\s*"([^"]+)"',
                  io.open("moonbit_doubleML/moon.mod", encoding="utf-8").read(),
                  re.M)
    return m.group(1)


V = ver()

# ==============================================================================
# 1.  THE LEDGER -- the project document
# ==============================================================================
#
# The whole previous README, in full.  The blocks that moved into the new
# README are NOT removed from it: the ledger is the historical document, and a
# ledger that drops the parts a reader might want to check against is not a
# ledger.  The banner says so.

LEDGER_HEAD = """# ENGINEERING notes -- `moonbit_doubleML`

> **This is the companion to `README.mbt.md`, not a second README.** The
> README is the document a user of the library needs: what it is, how to
> install it, how to call it, and where its sharp edges are. Everything that
> is *about this project* rather than *about the library* -- the CI harness's
> internals, the QA registry, the release-by-release history of the defects
> that moved the estimator defaults, and the archaeology behind the upstream
> naming map -- lives here instead.
>
> It was split out of the README on 2026-10-21 (round 18). The README was
> 2290 lines; it is now a document a person can read end to end.
>
> **Nothing was deleted.** What follows is the README as it stood at
> `v0.164.11`, in full and word for word -- including the blocks that are now
> in the README, because a ledger that drops the parts a reader might want to
> check against is not a ledger. The new README is a condensation of it.
>
> The records that hold the *measurements* are in `_verify/` and are
> referenced from both documents.
>
> **One correction, 2026-10-21 (round 21).** The propensity-margin paragraph
> further down quotes a **366x** separation for `DoubleMLIRM` and a **300x**
> one for `DoubleMLAPO`. Both figures were re-measured against the current
> tree and are **367x** and **320x**. The ledger's body is left exactly as it
> was published, because this document is a snapshot; `README.mbt.md` carries
> the corrected figures, and the measurement is in
> `_verify/_hazard_margins_1650.json`.

"""

ledger = LEDGER_HEAD + "## The README as it stood at v0.164.11\n\n" \
    + SRC.split("\n", 1)[1].lstrip("\n")

# ==============================================================================
# 2.  THE README -- the library document
# ==============================================================================

PITCH = blk(1, 28)

# The pitch's second sentence names the two renamed estimators.  "renamed" has
# to be in it: the provenance table and the pitch must use the same word for the
# same thing, and a verifier checks the count and the word together.  The
# rewrap keeps "**no 1:1 upstream class**" on one line for the same reason --
# a line break inside a bold phrase breaks every regex that looks for it.
PITCH = PITCH.replace(
    "**2** are upstream estimators under\na different name -- `DoubleMLRDD` is "
    "upstream's RDD estimator (upstream\ncalls it `RDFlex`) and "
    "`DoubleMLDIDCrossSection` is upstream's\n`DoubleMLDIDCS`; and **1**, "
    "`DoubleMLDIDCS`, has **no 1:1 upstream\nclass** -- it is this port's "
    "variant of upstream's multi-period\n`DoubleMLDIDMulti`, which upstream "
    "keeps in a single class that this\nport splits in two. Those provenance "
    "labels are re-measured against the\n**installed** `doubleml` 0.11.3 "
    "package, not asserted -- see the\nestimator table below and "
    "`_verify/UPSTREAM_PROVENANCE.md`.",
    "**2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream\n"
    "calls it `RDFlex`) and `DoubleMLDIDCrossSection` is upstream's\n"
    "`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream class**\n"
    "-- it is this port's variant of upstream's multi-period `DoubleMLDIDMulti`,\n"
    "which upstream keeps in a single class that this port splits in two. Those\n"
    "provenance labels are re-measured against the **installed** `doubleml`\n"
    "0.11.3 package, not asserted -- see the estimator table below and\n"
    "`_verify/UPSTREAM_PROVENANCE.md`.")

FEATURES = """## Features

- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (5), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below.
- ✅ **One API shape** -- `DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()`.
  Six estimators differ in their accessors; they are named rather than left
  to be discovered.
- ✅ **Cross-fitting infrastructure** -- `kfold`, repeated cross-fitting,
  stratified K-fold, a `chacha8_rng(seed)` PRNG, and Kahan summation.
- ✅ **Robust variance and inference** -- heteroskedasticity-consistent (HC)
  standard errors, cluster-robust variance, multiplier bootstrap confidence
  intervals, joint CIs, and Romano-Wolf multiple-testing adjustment.
- ✅ **Propensity-score processing** -- `PSProcessorConfig`: clipping,
  isotonic calibration, CV calibration, all reachable from an estimator.
- ✅ **Four backends** -- `native`, `wasm`, `wasm-gc`, `js` -- all green under
  `moon test --deny-warn`.
- ✅ **24 / 24 Python reference scripts PASS** -- 25 of the 25 bit-exact items
  and 6 / 6 RNG keys are IEEE-754 identical to CPython.
- ✅ **No runtime third-party dependency** -- the library imports nothing
  outside `moonbitlang/core`.
- ✅ **21 runnable example binaries**, an HTTP service, and a property-based
  fuzz harness.

"""

INSTALL = """## Installation

```bash
moon add riantr/moonbit_doubleML
```

Then reference it from `moon.mod`:

```moonbit nocheck
///|
import {
  "riantr/moonbit_doubleML@%(v)s",
}
```

"""

# The upstream-correspondence note, condensed.  The full derivation is in
# ENGINEERING.md; the README keeps the dated marker, because a reader who was
# told "this port has no upstream counterpart for DIDCS" deserves to see that
# the claim was corrected and when.
#
# The paths are CODE SPANS, not links, and that is deliberate: the README
# that ships is the only file the registry publishes, so a relative link to a
# file in the repository is a link to nowhere on the published page.  The
# old README used code spans for the same reason.
AMENDED = """> **AMENDED 2026-10-20 (round 16).** The naming map above was corrected
> in round 16: `DoubleMLDIDCS` has **no 1:1 upstream class** -- it is this
> port's variant of upstream's `DoubleMLDIDMulti` -- and the two *renamed*
> pairs are `DoubleMLRDD` (upstream `RDFlex`) and `DoubleMLDIDCrossSection`
> (upstream `DoubleMLDIDCS`). The derivation, and the parameter that
> distinguishes them, are in `_verify/UPSTREAM_PROVENANCE.md` and in
> `ENGINEERING.md`.

"""

# The RDD arm, verbatim, cut at the sentence boundary.  The next sentence in
# the old README ("The standing rule is the same one below") pointed at text
# that stayed in the ledger, so the pointer would dangle here.
RDD_ARM = blk(1369, 1378)
RDD_ARM = RDD_ARM[:RDD_ARM.index("than asserted.") + len("than asserted.")]

# The pitfalls, in the reference page's DO / DON'T shape.  The LPLR regime and
# the RDD arm are the old README's own paragraphs, kept verbatim -- they are
# the two places where the port's answer can be wrong in a way a user has to
# know about before trusting it.
PITFALLS = """## Common pitfalls and best practices

### ⚠️ Partially logistic regression: the small-n regime

This port damps LPLR's Newton step so the answer stays finite; upstream does
not. What follows is why that is a fragility the two implementations SHARE, and
not a defect this port introduced.

%(lplr)s

### ✅ DO

1. **Pass a classifier for `ml_m` wherever the propensity carries
   identification.** The estimators that need one default to
   `logistic_regression`; the ones that do not are named in **Propensity
   processing** above, with the measurement behind each. `ml_g` deliberately
   stays OLS -- it models `E[y | x]`, not `P(y = 1 | x]`.
   `LearnerDispatch::is_classifier()` reports which constructors qualify.
2. **Read the warnings.** `DoubleMLLPLR::fit()` can return a degenerate
   standard error, and it says so rather than returning a confident wrong
   number:

   ```moonbit
   let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
   for w in model.warnings() { println(w) }
   ```

3. **Treat `n < 200` as ill-posed for partially logistic regression.** Both
   this port and upstream fail there, in opposite directions, and the port
   damps its Newton step to keep the answer finite.

### ❌ DON'T

1. **Don't read a small-n LPLR standard error as an estimate.** At `n = 500`
   the port and upstream agree to ~0.007. Below that the gate is a *report*,
   not a guarantee.
2. **Don't assume every `adjust_ps` call forwards `cv`.** The `adjust_ps`
   call sites that do not forward `cv` are **eight**, in seven files:
   `apo.mbt:320`, `cvar.mbt:736`, `cvar.mbt:1005`, `did.mbt:628`,
   `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `quantile.mbt:217`
   and `ssm.mbt:671`. The only two that do are IRM's and IIVM's -- `cv=` is
   passed at `irm.mbt:430` and `iivm.mbt:525`.
3. %(rdd)s
"""

readme = []
A = readme.append

A(PITCH.rstrip() + "\n")
A(FEATURES)
A(blk(51, 77).rstrip() + "\n")
A(INSTALL % {"v": V})
A("## Quick Start\n\n" + blk(1492, 1518).rstrip() + "\n\n"
  + blk(1522, 1532).rstrip() + "\n")
A("## The 22 estimators\n\n" + blk(1611, 1623).rstrip() + "\n\n"
  + blk(1624, 1647).rstrip() + "\n\n" + blk(1649, 1658).rstrip() + "\n\n"
  + AMENDED)
A("## API reference\n\n" + blk(79, 97).rstrip() + "\n\n"
  + blk(1426, 1449).rstrip() + "\n")
A("## Propensity processing\n\n" + blk(116, 228).rstrip() + "\n")
A("## Cross-fitting\n\n" + blk(99, 114).rstrip() + "\n")
A("## Examples\n\n" + blk(1536, 1608).rstrip() + "\n")
A((PITFALLS
    .replace("%(lplr)s", blk(1134, 1162).rstrip())
    .replace("%(rdd)s", RDD_ARM.replace("\n", "\n   ").rstrip())))
A("## Development status\n\n" + blk(32, 47).rstrip() + "\n")
A("### Validated against upstream, not only against ourselves\n\n"
  + blk(1349, 1367).rstrip() + "\n")
A("### Numerical parity with CPython\n\n" + blk(1958, 1977).rstrip() + "\n")
A("### Not covered, so not claimed\n\n" + blk(2024, 2038).rstrip() + "\n")
A("### Honest policy trees (v0.98.0)\n\n" + blk(1753, 1782).rstrip() + "\n")
A("## Project layout\n\n" + blk(1786, 1814).rstrip() + "\n")
A("## Dependency rule\n\n" + blk(1818, 1836).rstrip() + "\n")
A("## Attribution\n\n" + blk(2244, 2274).rstrip() + "\n")
A("## Used By\n\n" + blk(2278, 2290).rstrip() + "\n")
A("""## Development

The test suite, the Python cross-checks, the QA harness and the
reproducibility commands are all documented in `ENGINEERING.md`, together with
the history of the defects that moved the estimator defaults and the
derivation of the upstream naming map. Both files are in the repository; the
registry publishes this one.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.
```

## License

MIT. The upstream package, `DoubleML/doubleml-for-py`, is BSD 3-Clause; this
port is MIT-licensed and credits it (see **Attribution** above).
""")

text = "\n".join(readme)
while "\n\n\n" in text:
    text = text.replace("\n\n\n", "\n\n")

# The version sites the old README carried are rewritten to the version in
# `moon.mod`.  The old README's own version is derived from its source, not
# typed in: the builder must not know the version it is building.
_m = re.search(r"\*\*(\d+\.\d+\.\d+)\*\*", SRC)
OLD_V = _m.group(1) if _m else ""
if OLD_V and OLD_V != V:
    text = text.replace("| `moon.mod` version | **%s** |" % OLD_V,
                        "| `moon.mod` version | **%s** |" % V)
    text = text.replace("(moon.mod v%s," % OLD_V, "(moon.mod v%s," % V)

# ==============================================================================
# 3.  THE ROUND-20 PATCH
# ==============================================================================
#
# The API reference promised that the differences between the estimators were
# "listed here rather than discovered later", and then listed only the
# ACCESSOR differences.  The CONSTRUCTOR differences are a different six --
# `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ` take `n_folds` and `seed` but
# no `n_rep`, and `DoubleMLBLP`, `DoubleMLRDD`, `DoubleMLPolicyTree` take
# none of the three -- and the two sets overlap in only three estimators.  A
# reader of `DoubleMLPQ` or `DoubleMLRDD` found nothing in the table, which
# is exactly the "discovered later" the sentence promised to prevent.
#
# The README is GENERATED, so the fix has to live here: an edit made to
# README.mbt.md directly would be reverted by the next bump.
#
# `_verify/_verify_ctor_options_1650.py` derives the groups from the
# constructors' signatures and checks the README against them.

OLD_API = """**One API shape, with the differences named** -- every estimator is built
`DoubleMLXxx::new(...).fit()`, with `n_folds` / `n_rep` / `seed` among the
labelled options. The *shape* is uniform; the signature and the accessor set
are not, and the six exceptions are listed here rather than discovered later:

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

The other 16 expose `.coef()` / `.se()` / `.confint()` / `.bootstrap()`.
Constructor arguments differ for the same reason: `DoubleMLDIDBinary` needs
`g_value` / `t_value_pre` / `t_value_eval`, `DoubleMLAPOS` needs
`treatment_levels`, `DoubleMLPolicyTree` needs `features` / `orth_signal` /
`depth` / `honest`, and each DID variant takes its own data type."""

NEW_API = """**One API shape, with the differences named** -- every estimator is built
`DoubleMLXxx::new(...).fit()`. The *shape* is uniform; the signature and the
accessor set are not, and **both** sets of differences are listed here rather
than discovered later. They are two different sets of six, and they overlap in
only three estimators.

**The accessor differences:**

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

The other 16 expose `.coef()` / `.se()` / `.confint()` / `.bootstrap()`.

**The constructor differences** -- which estimators take `n_folds` / `n_rep` /
`seed`. This is a different partition from the accessor table above, so the
two groups of "the other 16" are not the same sixteen:

| estimators | `n_folds` | `n_rep` | `seed` |
|---|---|---|---|
| the other 16 | yes | yes | yes |
| `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ` | yes | **no** | yes |
| `DoubleMLBLP`, `DoubleMLRDD`, `DoubleMLPolicyTree` | no | no | no |

The quantile estimators cross-fit once -- `solve_pq` has no repetition loop,
so there is no `n_rep` to set. The last three take no cross-fitting option
at all: `DoubleMLBLP` is given a basis and an orth signal, `DoubleMLRDD`
fits locally around a cutoff, and `DoubleMLPolicyTree` splits the sample
once for its honest split (its own `split_seed`).

Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and each DID variant takes
its own data type."""

PATCHES = [(OLD_API, NEW_API)]

# ==============================================================================
# 3b.  THE ROUND-21 PATCH -- two measured figures that were never right
# ==============================================================================
#
# The propensity-margin paragraph quoted three figures that the measurements do
# not support.  Round 21 re-ran both arms of both fixtures against the CURRENT
# tree and got:
#
#   DoubleMLIRM   worst default |bias| 0.19827515142504515
#                 best OLS      |bias| 72.7973000454581
#                 separation 367.15x
#   DoubleMLAPO   worst default |bias| 0.5306843118134537
#                 best OLS      |bias|  5.246423466298134
#                 worst default SE   0.2695805382351013
#                 best OLS      SE   86.2780366255941
#                 SE separation 320.03x
#
# So "recovers within 0.198" was false (the bias is 0.19828), "misses by at
# least 72.8" was false (the smallest miss is 72.7973), and "366x" and "300x"
# were both mis-ratios.  The 366x was a slip that had been copied through the
# v0.132.0 CHANGELOG entry, the v0.132.0 gate's comment, the v0.134.0 gate's
# comment, the README and the ledger.
#
# The figures are now stated as the MEASURED worst / smallest, at enough
# precision that the separation is DERIVABLE from the two numbers the reader
# can see: 72.797 / 0.1983 = 367.06 -> "367x", and 86.28 / 0.270 = 319.56 ->
# "320x".  A reader who divides gets the figure the document states.
#
# `_verify/_verify_hazard_margins_1650.py` checks every number in this
# paragraph against `_verify/_hazard_margins_1650.json`, so the paragraph and
# the measurement cannot drift apart.

OLD_MARGINS = """across three seeds: default recovers within `0.198`, an OLS propensity misses
by at least `72.8` -- a 366x separation on the coefficient. `DoubleMLAPO`
(true `E[Y | D=1] = 1.2`): default within `0.531`, OLS misses by as little as
`5.246` -- only ~10x. APO's standard error is the honest discriminator
(`0.270` vs `86.28`, a 300x separation), because the mechanism is that an"""

NEW_MARGINS = """across three seeds: the default's worst bias is `0.1983`, the OLS arm's
smallest bias is `72.797` -- a 367x separation on the coefficient.
`DoubleMLAPO` (true `E[Y | D=1] = 1.2`): the default's worst bias is `0.5307`,
the OLS arm's smallest bias is `5.2464` -- only ~10x. APO's standard error is
the honest discriminator (`0.270` vs `86.28`, a 320x separation), because the
mechanism is that an"""

PATCHES.append((OLD_MARGINS, NEW_MARGINS))

for _old, _new in PATCHES:
    _n = text.count(_old)
    if _n != 1:
        print("!! a README patch matched %d times (expected 1) -- ABORT" % _n)
        sys.exit(1)
    text = text.replace(_old, _new)
    print("   patched the API reference: %d -> %d chars" % (len(_old), len(_new)))

# ==============================================================================
# 4.  WRITE
# ==============================================================================
io.open("ENGINEERING.md", "w", encoding="utf-8", newline="\n").write(ledger)
io.open("README.mbt.md", "w", encoding="utf-8", newline="\n").write(text)
# the shipped copy must stay byte-identical to the edited one
shutil.copyfile("README.mbt.md", os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md"))

for name, body in (("README.mbt.md", text), ("ENGINEERING.md", ledger)):
    b = body.encode("utf-8")
    print("%-18s %7d bytes  %5d lines  CR=%d  BOM=%s"
          % (name, len(b), body.count("\n"), b.count(b"\r"),
             b.startswith(b"\xef\xbb\xbf")))
print("source: %s" % SRC_FROM)
