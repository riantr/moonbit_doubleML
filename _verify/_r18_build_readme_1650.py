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
> **Corrections, 2026-10-21.** This document's body is the README as it
> was published at `v0.164.11`, and a snapshot is not rewritten -- so the
> corrections live here, beside the corrected figures, and in
> `README.mbt.md`, which is the document the registry actually serves.
>
> * **Round 21.** The propensity-margin paragraph further down quotes a
>   **366x** separation for `DoubleMLIRM` and a **300x** one for
>   `DoubleMLAPO`.  Both figures were re-measured against the current tree
>   and are **367x** and **320x**.  The measurement is in
>   `_verify/_hazard_margins_1650.json`.
> * **Round 22.** The Examples section quotes **12** of the 16 CLI demos
>   printing a 95 % CI.  The count is **11**: the passage's own breakdown
>   names five demos that print none, and 16 - 5 = 11.  The 12 came from a
>   measuring regex whose last alternative matched ANY bracketed line, so
>   `examples/pava`'s `case[v0]` case label counted as an interval.  The
>   measurement is in `_verify/_cli_demo_ci_1650.json`.  Round 22 also
>   corrected thirteen passages of prose in the README -- among them a
>   paragraph that opened with half a sentence, a claim that one API shape
>   covered all 22 estimators when six constructors differ, and an estimator
>   list that summed to 21 under a headline that said 22.
> * **Round 23.** The opening sentence's "22 estimators in total" could be read
>   as UPSTREAM's count.  Upstream has **21** estimator classes -- the 19
>   name-identical ones plus `RDFlex` and `DoubleMLDIDCS` -- and the 22 is
>   this port's, which is what the next sentence's 19 + 2 + 1 says.  The
>   README now reads "with **22 estimators** in total".  The arithmetic
>   itself was never in doubt: `_verify/_verify_round16_provenance_1650.py`
>   derives the grouping from the INSTALLED upstream package.
> * **Round 24.** Two sentences used a bare count as a referent -- "the
>   largest margin of the four" and "all four earlier outcomes" -- without
>   saying which four.  They are the same four: `DoubleMLIRM`, `DoubleMLAPO`,
>   `DoubleMLAPOS` and `DoubleMLSSM`, the estimators migrated to a classifier
>   propensity by v0.138.0.  Both sentences now name them, and the set is
>   derived by `_verify/_verify_count_referents_1650.py` from the source's own
>   propensity defaults, so it cannot drift.  The QA LOOP's `gherkin` message
>   also read "29/29 mapped test names resolve", although 3 of the 29 are
>   prose citations that name no test at all; it now reports the split
>   recorded below -- 26 against real declarations, 3 prose-exempt -- so "All
>   29 resolve" means "29 of 29 under the check's own rule".
> * **Round 25.** Three NAMES in the README did not survive being used: the
>   LPLR snippet passed `alpha=1.5` to a constructor that has no `alpha`
>   (`alpha` is the DGP's), the nonlinear options were named by their
>   `LearnerDispatch` enum VARIANTS rather than by the package's constructor
>   functions, and the "21 runnable example binaries" bullet's own
>   decomposition summed to 19.  All three are fixed in the README, and the
>   LPLR snippet is fixed in the source docstring too.  The new check
>   `_verify/_verify_snippet_names_1650.py` derives every constructor's real
>   parameters from the package, so a snippet that passes a parameter that
>   does not exist is a failure, not a sentence.
> * **Round 26.** The upstream-provenance GROUPING was audited, and it was
>   right in the published README and wrong in three sibling documents.
>   `doc/001_introduction` named `DoubleMLDIDCrossSection` as "the one
>   port-only estimator"; `doc/004_estimators` stated the old grouping (20
>   name-matched, one renamed, one port-only) and called the port's
>   `DoubleMLDIDCS` "DID with repeated cross-sections" -- which is UPSTREAM's
>   `DoubleMLDIDCS`, the estimator this port calls
>   `DoubleMLDIDCrossSection`; and `skills/moonbit_doubleML.md` said "20
>   mirror upstream by name" and that `DoubleMLDIDCrossSection` "has no
>   upstream counterpart (port-only)".  All three predate
>   `_verify/UPSTREAM_PROVENANCE.md`, which was first tracked in v0.164.11,
>   so they were never reconciled with it.  The new check
>   `_verify/_verify_provenance_grouping_1650.py` derives the grouping from
>   the INSTALLED upstream package and the port's own source -- the one
>   shared name that is a coincidence is found mechanically (`DoubleMLDIDCS`:
>   upstream consumes the id-less `DoubleMLDIDData`, the port consumes the
>   id-bearing `DoubleMLDIDCSData`) -- and then checks that every document
>   which states the grouping states THAT one.
> * **Round 27.** The four TUTORIAL documents under `doc/` -- the ones a reader
>   opens AFTER the README, and which the README does not restate -- were
>   audited for the first time, and three of them carried false claims.
>   `doc/005_dgps` gave `make_irm_heterogeneous_data` the signature
>   `(n_obs, theta, seed)` when the source says `(n_obs, dim_x, seed)`, and
>   claimed every factory exposes `x_get()` / `y_get()` / `d_get()` when
>   `make_lplr_LZZ2020` returns an `LplrData` carrying `theta_get()` and
>   `data_get()` instead -- so the document's own usage example did not apply
>   to it.  `doc/003_quick_start` published three exact numbers and NOTHING
>   asserted them: the tutorial test called `ignore(fitted.coef())` and never
>   mentioned `confint()`; the test now asserts all three bit-exactly, which
>   keeps the test COUNT unchanged.  `doc/006_python_check` described ONE family
>   of Python cross-checks and claimed "No estimator ships without a Python
>   cross-check", which was true only because it counted the 9 `pyexample_*`
>   upstream gates it never mentioned -- three estimators (`DoubleMLAPO`,
>   `DoubleMLDIDMulti`, `DoubleMLQTE`) are covered ONLY by that family, and
>   three more (`DoubleMLDIDCS`, `DoubleMLDIDCrossSection`, `DoubleMLPLPR`)
>   only by the `validate_*` family.  That document's step 2 claimed every
>   `validate_*` script builds its reference "via the upstream
>   `doubleml.DoubleMLXxx`" -- true for 9 of the 24, false for the other 15 --
>   and the README said the `pyexample_*` family was the only one whose
>   reference is upstream, which 2 of the 9 wheel-importing `validate_*`
>   scripts also do (`validate_did_cs_binary_with_python.py` and
>   `validate_lplr_with_python.py`).  The new check
>   `_verify/_verify_tutorial_claims_1650.py` derives the DGP signatures, the
>   accessor sets, the 22-estimator coverage map and the 9/15 wheel split from
>   the source, and checks that a witness sits next to every published number.

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
- ✅ **One API shape** -- `DoubleMLXxx::new(...).fit()`. Two different sets of
  six differ -- six in their accessors, six in their constructors -- and both
  are named in **API reference** rather than left to be discovered.
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

# The upstream-correspondence note.  The full derivation is in ENGINEERING.md.
#
# ROUND 22: the note used to open with "**AMENDED 2026-10-20 (round 16).**".
# That is the project's own review vocabulary: "round 16" means nothing to a
# reader who has only the published page, and "AMENDED" promises a previous
# version they never saw.  The substance -- which names do not map 1:1, and
# where the derivation is -- is kept; the internal marker is not.  The naming
# map is already in the estimator table above, so what is left here is a
# pointer rather than a second copy of it.
#
# The paths are CODE SPANS, not links, and that is deliberate: the README
# that ships is the only file the registry publishes, so a relative link to a
# file in the repository is a link to nowhere on the published page.  The
# old README used code spans for the same reason.
AMENDED = """> **How the names map.** `DoubleMLDIDCS` has **no 1:1 upstream class**
> -- it is this port's variant of upstream's `DoubleMLDIDMulti` -- and the
> two *renamed* pairs are `DoubleMLRDD` (upstream `RDFlex`) and
> `DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`). The derivation, and
> the parameter that distinguishes them, are in
> `_verify/UPSTREAM_PROVENANCE.md` and in `ENGINEERING.md`.

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

# ==============================================================================
# 3b.  THE ROUND-23 PATCH -- whose 22 estimators?
# ==============================================================================
#
# The opening sentence is:
#
#   "A pure-MoonBit port of the `doubleml-for-py` Python package -- the Python
#    ecosystem's most mature Double / Debiased Machine Learning implementation
#    -- 22 estimators in total."
#
# The subject of that sentence is the PORT, so "22 estimators in total"
# predicates the port -- and the next sentence ("**19** match a class of the
# same name in upstream; **2** are renamed; and **1** has no 1:1 upstream
# class") sums to 22, which is the port's count.  Upstream has **21**
# estimator classes: the 19 name-identical ones plus `RDFlex` and
# `DoubleMLDIDCS`.  The arithmetic is right.
#
# But the appositive in the middle names the UPSTREAM package, and a reader
# who takes "22 estimators in total" to belong to it is told upstream has 22
# when it has 21.  The fix is one word and it makes the count parallel with
# the 19 / 2 / 1 that follow, which are all bold for exactly this reason.
#
# `_verify/_verify_round16_provenance_1650.py` already derives the grouping
# from the INSTALLED upstream package -- 21 upstream classes plus the one
# port estimator with no 1:1 class -- so the arithmetic this sentence
# describes is machine-checked; what was left was only the reading.

OLD_TWENTY_TWO = """package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- 22 estimators in total. **19** match a
class of the same name in upstream; **2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream"""

NEW_TWENTY_TWO = """package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- with **22 estimators** in total. **19** match a
class of the same name in upstream; **2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream"""

PATCHES.append((OLD_TWENTY_TWO, NEW_TWENTY_TWO))

# ==============================================================================
# 3c.  THE ROUND-22 PATCHES -- a line-by-line read of the published text
# ==============================================================================
#
# Round 22 read the built README line by line, the way a reader would, and
# checked every claim it makes against the tree.  Twelve passages were wrong,
# ambiguous or stale.  Each is corrected here, in the generator, for the
# reason round 21 used: README.mbt.md is BUILT, so an edit made to it
# directly is reverted by the next bump.
#
# Four of the twelve are factual and are recorded in the CHANGELOG as
# corrections; the rest are prose.  The comments below say what each one was
# and how it was checked, so a later reader can re-derive the correction
# instead of taking it on trust.
#
# P1. THE API CLAIM CONTRADICTED THE API REFERENCE.
# The pitch promised "a unified `DoubleMLXxx::new(data, n_folds, n_rep,
# seed).fit()` API across all 22 estimators", and the Features list said
# "One API shape ... Six estimators differ in their accessors".  But the
# API reference (added in round 20) lists TWO different sets of six -- the
# accessor six and the CONSTRUCTOR six -- and they overlap in only three
# estimators.  A reader who believed the pitch would write
# `DoubleMLBLP::new(data, n_folds, n_rep, seed)`, which does not compile.
# The six that differ in their constructor are named in the API reference.
OLD_API_SHAPE = """inside the MoonBit ecosystem. Delivers a unified
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` API across all
22 estimators, robust variance estimation, propensity-score
processing, multiple-testing correction, and a reproducible validation
pipeline (24 / 24 Python reference scripts PASS) -- on `native`,"""

NEW_API_SHAPE = """inside the MoonBit ecosystem. Delivers one
`DoubleMLXxx::new(...).fit()` API across all 22 estimators -- the shape
is the same, but six take a different constructor, and those six are
named in **API reference** -- with robust variance estimation,
propensity-score processing, multiple-testing correction, and a
reproducible validation pipeline (24 / 24 Python reference scripts PASS)
-- on `native`,"""

# P2. THE FEATURES LIST DID NOT ADD UP TO ITS OWN HEADLINE.
# "PLR, IRM, PLIV, IIVM, the DID family (5), SSM, ..." sums to 21, under a
# headline that says 22.  The estimator table has SIX DID-family estimators
# -- DID, DIDBinary, DIDCS, DIDCSBinary, DIDMulti, DIDCrossSection -- so
# "the DID family (6)" is the count that makes the list sum to 22.
OLD_DID_COUNT = """- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (5), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below."""

NEW_DID_COUNT = """- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (6), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below."""

# P3. THE EXAMPLE COUNT DOUBLE-COUNTED TWO OF ITS OWN ITEMS.
# "21 runnable example binaries, an HTTP service, and a property-based fuzz
# harness" reads as 23, because `examples/api_server/` and `examples/fuzz/`
# are two OF the 21.  The Project layout section names them, and the
# Examples section counts them separately, so the two figures were already
# in the same document.
OLD_EXAMPLE_COUNT = """- ✅ **21 runnable example binaries**, an HTTP service, and a property-based
  fuzz harness."""

NEW_EXAMPLE_COUNT = """- ✅ **21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
  consumer demo and a property-based fuzz harness."""

# P4. TWO PASSAGES DESCRIBED WHAT THE README USED TO SAY.
# "were for several releases described here as MoonBit-specific extras" and
# "were previously marked *(extra)*, which was wrong" are the document
# talking about its own history.  A reader who has only the published page
# has no "several releases" to compare against; the facts survive in the
# CHANGELOG and in the ledger, which is where a reader should look for them.
OLD_WAS_EXTRA = """`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` were for
several releases described here as MoonBit-specific extras; all three
ship upstream and the table marks them *(upstream)*."""

NEW_WAS_EXTRA = """`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` all ship
upstream, and the table marks them *(upstream)*."""

OLD_PREVIOUSLY_EXTRA = """partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- were previously marked *(extra)*,
which was wrong: all three ship upstream, so they had a reference
implementation all along."""

NEW_PREVIOUSLY_EXTRA = """partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- ship upstream, so each has a reference
implementation."""

# P5. THE "NUMERICAL PARITY" SECTION OPENED WITH A SENTENCE FRAGMENT.
# The block this section is built from starts at old-README line 1958, which
# is the SECOND half of a sentence: "patterns instead, against
# `examples/bitexact/`."  The subject -- and the tier statement that goes
# with it -- were at 1955-1957 and were dropped by the condensation.  A
# reader met a heading and then half a sentence.
OLD_BITEXACT_FRAGMENT = """patterns instead, against `examples/bitexact/`. Measured scope, not assumed --"""

NEW_BITEXACT_FRAGMENT = """**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell "the
port is arithmetically identical to the reference" apart from "the port lands
within 1e-4 of it". `validate_bitexact_with_python.py` compares IEEE-754 bit
patterns instead, against `examples/bitexact/`. Measured scope, not assumed --"""

# P6. "THE FOUR TREE/LOGISTIC LEARNERS" WAS THREE.
# The README's own learner table marks exactly three learners as
# classification -- `LogisticRegression`, `RFClassifier`, `GBClassifier` --
# and `learner.mbt:200-202` (`is_classifier()`) returns true for exactly
# those three.  `RFLearner` and `GBLearner` are regression learners: they
# predict a mean, not a probability, so they cannot be among "the four".
OLD_FOUR_LEARNERS = """learner surface. This package ships eleven. The four tree/logistic
learners' `predict` returns `P(y = 1 | x)` for classification, never a
hard label, because DML's AIPW correction divides by the fitted
propensity."""

NEW_FOUR_LEARNERS = """learner surface. This package ships eleven. The three classification
learners' `predict` returns `P(y = 1 | x)`, never a hard label, because
DML's AIPW correction divides by the fitted propensity."""

# P7. "12 OF THE 16 PRINT A 95 % CI" WAS NEVER TRUE.
# The README's OWN breakdown beside the figure names FIVE demos that print
# no CI -- pava, splitting, apos, cluster, ssm -- and 16 - 5 = 11, not 12.
# The 12 came from the measuring script's CI regex, whose last alternative
# was `\[.*\]`: ANY line with a bracket pair counts as an interval, and
# `examples/pava` prints `case[v0] n=4 pava = 0.625 ...`.  pava prints no
# interval at all.  Re-measured with a definition that has to be satisfied by
# an actual interval -- a confidence level, a named interval, or both
# endpoints -- the count is 11, and the 11 are apo, cvar, datasets,
# did_binary, did_cross_section, did_cs, did_cs_binary, did_multi, lplr,
# main and plpr.  `_verify/_verify_cli_demo_ci_1650.py` re-derives it.
OLD_CI_COUNT = """demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **12** of the 16 print a 95 % CI -- `examples/pava` and"""

NEW_CI_COUNT = """demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **11** of the 16 print a 95 % CI -- `examples/pava` and"""

# P8. "AGENTS.md <- this file" COULD BE READ AS THE README.
# Every other line in that tree names its own file, so "this file" is
# ambiguous in the one place where the reader has an antecedent in mind --
# the document they are reading.
OLD_AGENTS_LINE = """AGENTS.md                <- this file (per moonbit agent convention)"""

NEW_AGENTS_LINE = """AGENTS.md                <- agent guide for coding agents (MoonBit convention)"""

# P9. A HEADING SKIPPED A LEVEL.
# `## Attribution` was followed by `#### Differences from upstream`, so the
# subsection was two levels down with nothing at the level in between.
OLD_ATTRIB_HEADING = """#### Differences from upstream `doubleml-for-py`"""

NEW_ATTRIB_HEADING = """### Differences from upstream `doubleml-for-py`"""

# P10. "ONE SCRIPT PER UPSTREAM CLASS" WAS NOT TRUE OF ITS OWN TABLE.
# `pyexample_pq.py` drives three upstream classes and `pyexample_suite.py`
# drives a family.
OLD_ONE_SCRIPT = """implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class:"""

NEW_ONE_SCRIPT = """implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class or family:"""

# P11. A VERSION PROMISE THAT WAS 80 RELEASES STALE.
# "a v0.82+ release can swap the bodies" read as a release still to come.
# The API has been fixed since v0.82; the package is at v0.164.x.
OLD_V082 = """today -- the public API is fixed so a v0.82+ release can swap
the bodies to a SIMD-vectorised backend (or external call to
a BLAS-style library) without breaking callers."""

NEW_V082 = """today -- the public API has been fixed since v0.82, so a future
release can swap the bodies to a SIMD-vectorised backend (or external
call to a BLAS-style library) without breaking callers."""

# ==============================================================================
# 3d.  THE ROUND-24 PATCHES -- two counts whose set a reader could not resolve
# ==============================================================================
#
# Two sentences used a bare count as a referent: "the largest margin of the
# four" and "all four earlier outcomes".  Both fours are the SAME four --
# DoubleMLIRM, DoubleMLAPO, DoubleMLAPOS and DoubleMLSSM -- but neither
# sentence said so, and the section offers two different candidate fours a
# few paragraphs apart.
#
# Where the referents came from, and why they are the same set:
#
#   * The SSM sentence was written in v0.138.0, the release that migrated
#     SSM's propensity default.  At that revision the paragraph above it
#     opened "The four migrations do NOT have the same margin" and the
#     paragraph before that listed exactly four migrations -- IRM (v0.132.0),
#     APO (v0.134.0), APOS (v0.135.0), SSM (v0.138.0).  A later condensation
#     dropped the count from "The four migrations" ("The migrations do NOT
#     all have the same margin") and left "the four" with no antecedent.
#   * The classifier sentence was written one release earlier, in v0.137.0,
#     when the four hazardous verdicts were exactly those same four; the
#     fifth, DoubleMLIIVM, is the case that refutes the classifier.
#
# Both sets are DERIVED, not asserted: `_verify/_verify_count_referents_1650.py`
# derives the four from the source (the estimators whose propensity default
# is a classifier) crossed with the README's own migration releases, and
# checks that each of these two sentences names all four.  The classifier
# sentence's own wording changed with it: "all four earlier outcomes" is now
# "the four hazardous verdicts of v0.132.0-v0.138.0", because "earlier
# outcomes" pointed at nothing and the release range is what separates these
# four from the two that turned out hazardous later (PQ and QTE, v0.139.0).

OLD_SSM_MARGIN = """`DoubleMLSSM` has the largest margin of the four, because its score carries
**two** reciprocals, one per direction (`ssm.mbt:73-74`): the treatment
propensity `m` and the selection propensity `pi`, so an unbounded regressor
breaks both denominators independently. On a saturated fixture with true
`theta = 1.0`, the OLS arm returns `242.116` with SE `185.45` where the
classifier returns `1.177` with SE `0.0982` -- roughly **200x** on the point
estimate and **1900x** on the standard error. Across three seeds the OLS
coefficient also **changes sign** (`+242`, `+106`, `-452`); the classifier's
spread over the same three seeds is `0.761`."""

NEW_SSM_MARGIN = """`DoubleMLSSM` has the largest margin of the four migrations of
v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and
`DoubleMLSSM` -- because its score carries **two** reciprocals, one per
direction (`ssm.mbt:73-74`): the treatment propensity `m` and the selection
propensity `pi`, so an unbounded regressor breaks both denominators
independently. On a saturated fixture with true `theta = 1.0`, the OLS arm
returns `242.116` with SE `185.45` where the classifier returns `1.177` with
SE `0.0982` -- roughly **200x** on the point estimate and **1900x** on the
standard error. Across three seeds the OLS coefficient also **changes sign**
(`+242`, `+106`, `-452`); the classifier's spread over the same three seeds
is `0.761`."""

OLD_CLASSIFIER = """A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces all four earlier outcomes
-- but `DoubleMLIIVM` **refuted** it, carrying `1/m` and `1/(1-m)` on every row
and still measuring harmless. A reciprocal in the score is not sufficient for
the hazard; the classifier is a way to decide what to measure first, nothing
more."""

NEW_CLASSIFIER = """A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces the four hazardous
verdicts of v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`,
`DoubleMLAPOS` and `DoubleMLSSM` -- but `DoubleMLIIVM` **refuted** it,
carrying `1/m` and `1/(1-m)` on every row and still measuring harmless. A
reciprocal in the score is not sufficient for the hazard; the classifier is a
way to decide what to measure first, nothing more."""

# ==============================================================================
# 3e.  THE ROUND-25 PATCHES -- three names that did not survive being used
# ==============================================================================
#
# Round 25 read the published README line by line once more and found three
# places where the text names something the package does not have.
#
# P12. THE LPLR SNIPPET PASSED A PARAMETER THAT DOES NOT EXIST.
# "DoubleMLLPLR::new(data, alpha=1.5)" -- `DoubleMLLPLR::new` takes `data`,
# `score`, `n_folds`, `n_folds_inner`, `n_rep`, `seed`, `ml_g` and `ml_m`
# (`lplr.mbt:352-363`).  There is no `alpha`, on the constructor or on `fit`:
# `alpha` is the DGP's (`dgp_lplr.mbt:37`), not the estimator's.  The README
# offers the snippet as copy-pasteable, in a plain `moonbit` fence, so a
# reader who copies it gets a compile error.  The same wrong line sits in the
# source docstring at `lplr.mbt:449`; that one is fixed in the source, here.
#
# P13. THE NONLINEAR OPTIONS WERE NAMED BY THEIR ENUM VARIANTS.
# `LearnerDispatch::RandomForestClassifier` and
# `LearnerDispatch::GradientBoostingClassifier` are VARIANTS of the enum
# (`learner.mbt:165,169`); the package's own constructors are the functions
# `LearnerDispatch::random_forest_classifier` and
# `LearnerDispatch::gradient_boosting_classifier` (`learner.mbt:268,279`).
# Every other `LearnerDispatch::` name in the README is a function, so this
# was the one place a reader could copy a name that is not callable the way
# the rest of the document says it is.
#
# P14. A FIGURE AND ITS OWN DECOMPOSITION DID NOT AGREE.
# "**21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
# consumer demo and a property-based fuzz harness" sums to 19.  The two
# missing ones are `examples/bitexact/` and `examples/parity/`, which the
# README's own Examples section calls "kept as runnable binaries".  Round 22
# rewrote this bullet from a form with no decomposition at all into one that
# has one, and the decomposition it wrote was short by two.

OLD_LPLR_SNIPPET = """   ```moonbit
   let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
   for w in model.warnings() { println(w) }
   ```"""

NEW_LPLR_SNIPPET = """   ```moonbit
   let model = DoubleMLLPLR::new(data).fit()
   for w in model.warnings() { println(w) }
   ```"""

OLD_NONLINEAR = """`LearnerDispatch::RandomForestClassifier` and
`LearnerDispatch::GradientBoostingClassifier` are the nonlinear options."""

NEW_NONLINEAR = """`LearnerDispatch::random_forest_classifier(RFClassifier::new(...))` and
`LearnerDispatch::gradient_boosting_classifier(GBClassifier::new(...))` are
the nonlinear options."""

OLD_EXAMPLES_BULLET = """- ✅ **21 runnable example binaries** -- 16 CLI demos, an HTTP service, a
  consumer demo and a property-based fuzz harness."""

NEW_EXAMPLES_BULLET = """- ✅ **21 runnable example binaries** -- 16 CLI demos, plus
  `examples/api_server/` (the HTTP service), `examples/consumer_demo/`,
  `examples/fuzz/`, and the two fixtures `examples/bitexact/` and
  `examples/parity/`."""

# ==============================================================================
# 3g.  THE ROUND-27 PATCH -- the `validate_*` family is not exclusively ours
# ==============================================================================
#
# The paragraph said: "Every script above compares the port against a second
# implementation written in this repository, which can only catch a disagreement
# someone already thought to look for."  The first half is true of all 24.  The
# second half is not: 9 of the 24 import the upstream `doubleml` wheel, and 2 of
# those 9 GATE THE PORT AGAINST UPSTREAM rather than only against a hand-rolled
# reference --
#
#   * validate_did_cs_binary_with_python.py: `if up is not None and
#     abs(mb["coef"] - up["coef"]) > MODEL_TOL: ok = False`
#   * validate_lplr_with_python.py: `band_ok = d_up < band and d_hr < band`,
#     where `d_up = abs(mb_theta - th_up)` and `th_up` is upstream's theta.
#
# So the `pyexample_*` family was not the only one able to catch a shared
# misreading of the model, and the README said it was.  The other 7 wheel
# importers use upstream for context (upstream's numbers are printed) and, in
# three of them, for separately gated rows of upstream's own quantities.
#
# Measured by _verify/_verify_tutorial_claims_1650.py, which derives the 9/15
# split from the scripts themselves (the upstream wheel is imported in code,
# not mentioned in prose) and checks both named gates still compare the port
# against upstream.

# The anchor runs to the end of the paragraph, so the new text can end with a
# clean paragraph break and the table's own intro can start on a fresh line.
# It matches the text as round 25's P10 left it ("class or family:").

OLD_UPSTREAM_OWNED = """**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which can only catch a disagreement someone already
thought to look for. The `pyexample_*` scripts instead run upstream's own code
on the port's rows and compare that: not "does the port agree with our second
implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class or family:"""

NEW_UPSTREAM_OWNED = """**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which on its own can only catch a disagreement
someone already thought to look for. The `pyexample_*` scripts instead run
upstream's own code on the port's rows and compare that: not "does the port
agree with our second implementation" but "does the port agree with upstream".

The `validate_*` family is not exclusively ours, though: **9** of its 24
scripts import the upstream `doubleml` wheel, and **2** of those gate the port
against upstream rather than only against a hand-rolled reference --
`validate_did_cs_binary_with_python.py` (the port's ATT against upstream's)
and `validate_lplr_with_python.py` (the port's coefficient against upstream's
*and* the hand-rolled one, together). The other **7** import the wheel for
context (`validate_apos`, `validate_cluster_iv`, `validate_cluster_plr`,
`validate_iivm`, `validate_irm`, `validate_pliv`, `validate_plpr`); upstream's
numbers are printed there, and in some of them upstream's own quantities are
separately gated rows.

Measured designs, one script per upstream class or family:"""

for _old, _new in ((OLD_API_SHAPE, NEW_API_SHAPE),
                    (OLD_DID_COUNT, NEW_DID_COUNT),
                    (OLD_EXAMPLE_COUNT, NEW_EXAMPLE_COUNT),
                    (OLD_WAS_EXTRA, NEW_WAS_EXTRA),
                    (OLD_PREVIOUSLY_EXTRA, NEW_PREVIOUSLY_EXTRA),
                    (OLD_BITEXACT_FRAGMENT, NEW_BITEXACT_FRAGMENT),
                    (OLD_FOUR_LEARNERS, NEW_FOUR_LEARNERS),
                    (OLD_CI_COUNT, NEW_CI_COUNT),
                    (OLD_AGENTS_LINE, NEW_AGENTS_LINE),
                    (OLD_ATTRIB_HEADING, NEW_ATTRIB_HEADING),
                    (OLD_ONE_SCRIPT, NEW_ONE_SCRIPT),
                    (OLD_V082, NEW_V082),
                    (OLD_SSM_MARGIN, NEW_SSM_MARGIN),
                    (OLD_CLASSIFIER, NEW_CLASSIFIER),
                    (OLD_LPLR_SNIPPET, NEW_LPLR_SNIPPET),
                    (OLD_NONLINEAR, NEW_NONLINEAR),
                    (OLD_EXAMPLES_BULLET, NEW_EXAMPLES_BULLET),
                    (OLD_UPSTREAM_OWNED, NEW_UPSTREAM_OWNED)):
    PATCHES.append((_old, _new))

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
