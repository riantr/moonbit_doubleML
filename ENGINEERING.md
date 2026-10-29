# ENGINEERING notes -- `moonbit_doubleML`

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
> * **Round 28.** The `score` argument was audited -- where it lives, what it
>   accepts, and which estimators have one at all.  The port has **9** `score`
>   parameters at **7** estimators: `DoubleMLPLR` takes it on `fit()` (also on
>   `fit_cluster()` and `tune()`), six others take it on `new()`, and **15 of
>   the 22 take no score argument at all**.  `doc/004_estimators` said the
>   column was "the value you pass to `fit(score=...)`" -- true for exactly one
>   estimator -- and it filled the other rows with the strings `apo`, `apos`,
>   `pq`, `qte`, `lpq`, `cvar` and `policy_tree`, which are the port's
>   INTERNAL cache-kind tags (the `hash_hyperparams(...)` kind, and
>   `policy_tree` the `estimator_kind`), not score values.  The README's
>   "three vocabularies" note repeated the mistake: five of the eight strings
>   it listed as accepted by the port are ones no estimator accepts, and the
>   upstream list gave 9 of the **15** spellings upstream actually uses --
>   `ATTE`, `LATE`, `experimental`, `instrument`, `nonignorable` and
>   `IV-type` were missing.  The API reference's "constructor arguments also
>   differ" paragraph did not name the one difference that moves between
>   `new()` and `fit()`.  `skills/moonbit_doubleML.md` said `ml_m` defaults to
>   the classifier "for the six estimators whose propensity enters the score as
>   `1 / m_hat`" and then named **seven** -- the seventh, `DoubleMLLPLR`, is
>   not one of them, because its propensity enters its score as `d - m_hat` --
>   and it said all 24 `validate_*` scripts re-derive the hand-rolled
>   reference, which is true of **15**: the other nine take theirs from
>   upstream's wheel.  The new check
>   `_verify/_verify_score_argument_1650.py` derives all of it from the
>   source: the score parameters and their owners, the accepted set at each
>   site, the cache-kind tags, and both vocabularies -- the upstream one
>   measured on the vendored 0.11.4 tree AND on the installed 0.11.3, which
>   agree.
>
>   The published count was wrong once, and the error is worth recording.  The
>   first entry said the new verifier runs **127** checks.  It runs **135** checks
>   on the tree as it stands.  The 127 was a real number -- but it was the
>   number the dry-run's transcript reports, and the dry-run measures the
>   verifier on a DELIBERATELY BROKEN tree, where two of its loops are shorter
>   (one fewer score site in doc/004's table, one fewer score parameter in the
>   source), so four checks do not execute.  A number of the wrong thing is
>   still a wrong number, and the two counts sat side by side in one tracked
>   log with nothing saying which was which.  The verifier now ASSERTS its own
>   published count, and the dry-run asserts the failure count it ends at.
> * **Round 29.** The PUBLIC API DOCSTRINGS -- the `///` blocks a user reads in
>   an IDE -- were audited for numbers for the first time, and three carried
>   counts that had gone stale.  `DoubleMLLPQ::bias_corrected_coef` said it was
>   "Identical in reasoning to the **twelve** `bias_corrected_coef` methods
>   added in v0.86.0 - v0.92.0", but that range holds **thirteen** (the twelve
>   that landed at v0.91.0, plus `DoubleMLLPLR` at v0.92.0);
>   `DoubleMLPQ::bias_corrected_coef` said "**thirteen** ... v0.86.0 - v0.93.0",
>   which holds **fourteen**; and the canonical `bias_corrected_theta` docstring
>   in `sandwich.mbt` -- the one every other docstring cites as "the full
>   argument" -- said "All **twelve** `bias_corrected_coef` methods are now
>   documented no-ops" when there are **fifteen** by that name.  The pattern is
>   exact: each author counted the family as of the version BEFORE the
>   immediately preceding addition.  `DoubleMLLPLR` (v0.92.0) says twelve and
>   is RIGHT; `DoubleMLLPQ` (v0.93.0) says twelve and is wrong by one;
>   `DoubleMLPQ` (v0.94.0) says thirteen and is wrong by one; `DoubleMLQTE`
>   (v0.95.0) says fifteen and is RIGHT.  The new check
>   `_verify/_verify_docstring_counts_1650.py` derives the `bias_corrected*`
>   family from the SOURCE -- its members, each one's self-declared
>   `vX.Y.Z+:` version, and the count of members in any stated range -- and
>   asks the five docstrings that publish a count of that family whether they
>   agree.  It also gates the other package-wide counts in the public
>   docstrings, each derived rather than asserted: the 22-estimator roster, the
>   15-estimator sandwich family, upstream 0.11.4's 21 estimator classes and
>   the 17 of them whose `cf` default is `0.03`, upstream's 7
>   `_sensitivity_implemented` estimators and 12
>   `init_ps_processor` callers, the 5 `RDDKernel` variants and the 3 of them
>   that are negative outside `|u| <= h`, the policy tree's 5-slot encoding,
>   the `GainStatsResult` field count, the `DoubleMLDIDBinary` delegation
>   count, the `hash_data` row sample and the logistic defaults.
>
>   Two things about how it reads the tree are worth recording.  It reads the
>   DOCSTRING, not the file: `fit_cache.mbt` says "first 10 + last 10" in a
>   `//` code comment as well as in the `hash_data` docstring, and a
>   whole-file search is satisfied by the comment a reader never sees.  And
>   its check count is FIXED, not tree-dependent: the five publishing sites
>   are a named list and every other check is an aggregate, so a site whose
>   docstring is destroyed reports a FAILED CHECK rather than a skipped one
>   and the count cannot move.  That is the lesson from v0.164.22, where the
>   published count was the one measured on the dry-run's broken tree.
>   `_verify/_dryrun_round29_1650.py` breaks each of the fifteen claims one at
>   a time and requires the failure count to GROW at every step, and it ends
>   at **29** failures.  Two of its mechanisms are worth noting: one moves a
>   member's self-declared version and one removes a member from the SOURCE,
>   so the derived counts change and the publishers that still state them are
>   caught -- nothing in the verifier is hard-coded to "the family has fifteen
>   members".  An early draft of that driver had a mechanism that REPAIRED an
>   earlier one's failure -- moving one publisher's range moved the derived
>   count onto exactly the value the previous mechanism had broken -- so the
>   failure count went flat on a tree that was still broken.  Each mechanism
>   now has a site of its own, and the one that changes the derived family
>   SIZE runs last, because it would otherwise break the checks the other
>   mechanisms are aimed at.
> * **Round 30.** The `file:line` CITATIONS in the tracked prose -- the last
>   prose surface no earlier round had audited -- were checked for the first
>   time.  A citation is a PROMISE: the thing this sentence names is AT that
>   line.  Nothing kept that promise, because the port's `.mbt` files are
>   edited every release and a citation written for one release points at
>   whatever happened to be on that line in the next one -- and the sentence
>   still READS FINE, because the sentence is never re-read.
>
>   Measured at v0.164.23: the tracked prose carried **102** citations into
>   this repo, in **42** files, and **64 of them** did not point at a line
>   that mentions the thing the sentence names.  The four that had broken
>   worst were `did_binary.mbt:445` (cited for the four-row dummy inner
>   model; line 445 is a `catch` arm), `lplr.mbt:1630` (cited for
>   `set_sample_splitting`; line 1630 is a prediction assignment, the
>   function is at 2022), `lplr.mbt:758` (cited for the `kfold` draw; line
>   758 is a loop header, the draw is at 781) and `did_cs.mbt:1263` (cited
>   for the panic on a 3-row stub; line 1263 is an unrelated `require`, the
>   panic site is `did.mbt:276`).  All 64 are repaired, and the prose
>   carried **103** citations in **40** files that all resolved.
>
>   The new check `_verify/_verify_citations_1650.py` asks a mechanical
>   question of each of them: does the cited line MENTION the thing the
>   sentence names?  It uses the LONGEST IDENTIFIER the sentence names rather
>   than the whole quoted string, because the prose is allowed to write the
>   maths where the code writes numpy and the identifier is what both
>   spellings share.  It reads the prose in PARAGRAPHS, so a claim whose
>   quote and whose citation sit on adjacent wrapped lines still binds, and it
>   takes the anchor from the quoted token CLOSEST to the citation, with the
>   one BEFORE winning when the two sides are within eight characters.  A
>   citation with no code beside it is UNCHECKABLE and FAILS: the fix is to
>   quote the code, not to loosen the check.
>
>   Only the citations that name a file IN THIS REPO are checked.  A citation
>   that names an upstream Python file is a promise about a pinned third-party
>   package (`doubleml` 0.11.4) that this repo does not ship, and the
>   vendored upstream tree is not tracked, so a tracked verifier could not
>   check them anyway.  That count -- **266** -- was DECLARED and asserted
>   too, so the set could not move silently in either direction, and both
>   counts being declared is what kept the published check count FIXED at
>   **108**.
>
>   `_verify/_dryrun_round30_1650.py` breaks each of the eight mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **9** failures.  Two of its mechanisms are worth recording, both
>   because the first draft got them WRONG.  The mechanism that reproduces
>   the rot itself -- a source file grows a line above a cited one -- was
>   first aimed at `dgp_did_CS2021.mbt:50-51`, a RANGE citation, and it
>   contributed NOTHING: inserting a line above a two-line range leaves the
>   content inside the window, so the citation still resolved.  And the
>   mechanism that truncates a file was first aimed at `ps_processor.mbt`,
>   whose tail carries an upstream-side citation: the truncation moved the
>   upstream count from 266 to 265 as a SIDE EFFECT, and the mechanism that
>   moves that count on purpose put it back, so the failure count went flat
>   on a tree that was still broken.  That is the same trap as round 29's,
>   and the fix is the same: each mechanism has a site of its own, and the
>   one that changes the derived set SIZE runs last.
>
>   The ledger body below is a `v0.164.11` snapshot, so its own line pointers
>   name where the code was THEN; round 30 moved some of those lines again.
>   The CURRENT pointers live in the records under `_verify/`, and round 30
>   re-anchored the four of them that round 30's own repairs had moved.
>
> * **Round 31.** The **21** example manifests under `examples/` each import
>   the library BY VERSION, and every one of them named a version long gone:
>   **19** pinned `0.52.0` and **2** (`examples/bitexact/`,
>   `examples/parity/`) pinned `0.162.0`, against a package at `0.164.24` --
>   **159** and **34** releases behind respectively, counted from the
>   CHANGELOG's own version headings.  Nothing could see it: inside the
>   WORKSPACE the pin is INERT, because the workspace member wins, so every
>   example built against the current library while its manifest named an
>   ancient one.  Outside the workspace the pin decides what gets installed,
>   and the README invites the reader to copy an example out of the tree.
>   All **21** now pin the library's current version, and the manifests are
>   **bump sites**: `_verify/_bump_1636.py` re-pins them with every release,
>   so they cannot drift again.  That was not optional -- the round-9 check
>   requires every tracked file carrying a current-version literal to be a
>   site the bump script covers, so re-pinning the examples without adding
>   them there would have failed that check on the next release.
>
>   The new check `_verify/_verify_example_pins_1650.py` runs **28** checks:
>   one per manifest, the derived library version, the declared count of
>   **21** examples, a stale-literal scan over the version SITES (the set the
>   bump script owns, so "every site" is a NAMED set rather than a guess),
>   the README's own install block, and the published count itself.  The scan
>   covers the version sites only: a historical record may name an old
>   version on purpose -- `CHANGELOG.md` and the `_verify/` records are
>   exactly where an old version belongs -- while a MANIFEST is a promise
>   about what to install, and a promise of an old version is a defect.
>
>   `_verify/_dryrun_round31_1650.py` breaks each of the five mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **8** failures.  The last mechanism moves the SET SIZE -- a new
>   example manifest appears -- so it runs last, because it would otherwise
>   break the checks the other mechanisms are aimed at.
>
>   Two numbers in the tree were wrong in the same way, and both are fixed
>   here.  The api_server's `/version` handler said the package was "109
>   releases ahead"; the CHANGELOG's version headings put it at **124** --
>   the gap at the last release that still advertised `0.52.0`, and also
>   the number of releases the drift went unnoticed for.  Its closing
>   sentence said a version bump "touches FOUR places" -- it touched that
>   many when it was written, and it touches every place the version lives
>   now, so it names `_verify/_bump_1636.py` instead of counting.  The bump
>   script's own docstring said "Nine sites" and listed seven; it now lists
>   every place instead of counting them.
>
>   Not touched: the examples' OWN `version` fields.  Those are the example
>   packages' versions, they are never published, and they do not track the
>   library today (`examples/parity` says `0.1.0`), so changing them would
>   be a new convention rather than a broken promise.  Nor is
>   `examples/api_server`'s `moonbitlang/async@0.20.3` pin -- a published
>   third-party dependency, out of scope here.
>
> * **Round 32.** The README's quoted MEASUREMENTS were audited for the first
>   time as a set, and two of the ratios it states were not the numbers they
>   claimed to be.  The LPLR pitfall said the derivative was `-8.07e-05`
>   "against a score of `-0.1119`, a factor of **344** down" -- but that
>   quotient is **1387**.  The 344 is real: it is the derivative's fall from
>   `-0.0277` at `theta0 = 1.003` to `-8.07e-05` at `theta0 = 6.842`, which
>   is what the witness script prints ("derivative falls by a factor of
>   343.5") and what the record's section 27f says.  The passage attached the
>   number to the wrong pair, so a reader could not check it; it now names
>   both start values, and 344 is the quotient of the two derivatives it
>   prints.  And the hazard table's `DoubleMLIIVM` row said "`0.987` vs
>   `1.031` (16x *smaller* SE)" without printing the standard errors, so the
>   16 was a number with no arithmetic behind it in the document; the row now
>   prints them (`0.0047` vs `0.0747`), in the OLS-first order the table uses
>   everywhere else.  The v0.163.4 entry that carried the first wording is
>   corrected too.
>
>   The new check `_verify/_verify_measurements_1650.py` runs **46** checks
>   over three invariants:
>
>   * every RATIO the README states must be DERIVABLE from the numbers its
>     own passage prints -- and a table row is its own passage, so a ratio in
>     a cell is measured against that cell and not against the table.  The
>     rule is general: it is not a list of the ratios, it is the arithmetic
>     of every ratio the document states.
>   * every number in a TABLE CELL must be the correctly-ROUNDED rendering of
>     a value in the CHANGELOG entry that names that row's estimator -- the
>     witness set is derived from the entries, not listed.
>   * every SMALL-N figure must be the correctly-rounded rendering of a value
>     in the record the README cites for that passage.
>
>   The rounding is by SIGNIFICANT DIGITS, so `0.531` is accepted against a
>   measured `0.5307` and `8.07e-05` against `-8.06571e-05` -- a rendering of
>   the measured value, not a different value.  The hazard table's cells had
>   been quoted from the v0.132.0-v0.142.0 measurement rounds since they were
>   written, and this is the first check that re-derives them.
>
>   `_verify/_dryrun_round32_1650.py` breaks each of the six mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **10** failures.  The last mechanism moves the SET SIZE -- a new
>   table row appears -- so it runs last, because it would otherwise break
>   the checks the other mechanisms are aimed at.
>
>   The check's own EVIDENCE was wrong at first, and it is worth recording
>   because it is the same failure the round exists to remove.  The verifier
>   stored the dividend and the divisor in whichever order the loop reached
>   them, and printed `0.5307 / 5.2464 = 9.9` -- a false equality in the
>   very tool that checks the README's arithmetic.  The verdicts were right;
>   the evidence printed beside them was not.  The pair is now ordered, so
>   every line is true as printed (`5.2464 / 0.5307 = 9.9`), and a
>   percentage prints both the fraction and the percentage (`17 / 40 =
>   0.4250 = 42.5%`).
>
> * **Round 33.** The propensity table's four measurements had never been
>   checked, and its third column could not be read at all.
>
>   The README writes every measured value in a CODE SPAN, and the check that
>   holds a table cell to the record reads a cell's numbers out of those
>   spans.  The propensity table wrote its numbers in bold and plain instead,
>   so `-225.86`, `0.043`, `1.44` and `0.842` fell outside the rule that was
>   supposed to cover them.  They were checkable all along: the v0.131.9
>   record holds `-225.86204067169143`, `0.043343170315623715`,
>   `1.4426392091401607` and `0.8419771777915093`.  The table now writes them
>   the way the rest of the document does, and the cell set grows from 20 to
>   **27** -- every new cell witnessed by the record that measured it.
>
>   The table's third column is headed `rv`, and the README never said what
>   `rv` IS.  It is upstream's **robustness value** -- the sensitivity-
>   analysis reading of how much confounding the estimate survives, so
>   **higher is more robust**.  The direction comes from this repository's own
>   records: v0.131.7 says a `nu2` pinned at 1 "claimed a robustness value of
>   19.6, i.e. 'robust to enormous confounding', where the correct value is
>   0.84", and v0.131.5 says a DID ATT of 1.02 "scored `rv = 7.77` (visibly
>   robust) when the correct value is `1.73` (fragile)".  Two other rows
>   broke the same convention -- the QTE row's tau bounds and the DIDBinary
>   row's `~1e-4` -- and are fixed the same way.
>
>   The fourth invariant makes the convention a CHECK rather than an
>   assumption: a table's measurements must be written in code spans.  A
>   convention nobody enforces decays, and this one decayed unnoticed for
>   twenty releases.  `_verify/_verify_measurements_1650.py` now runs **70**
>   checks over four invariants.
>
>   `_verify/_dryrun_round33_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **9** failures.  The last mechanism moves the SET SIZE -- a
>   measurement loses its code span -- so it runs last, because it would
>   otherwise break the checks the other mechanisms are aimed at.  The sixth
>   breaks the CONVENTION without moving the cell set, so the new rule's
>   verdict is visible on its own rather than riding along with the set-size
>   check.
>
>   The v0.164.26 entry's published failure count is corrected from 9 to
>   **10**: that count is tree-dependent by design, and round 33 added a
>   check.  Each dry-run reads its count from the entry that names it, so
>   neither can be read in place of the other.
>
> * **Round 34.** The tree that is RELEASED must be the tree that was
>   TESTED, and until this round nothing checked that.
>
>   The `v0.164.27` tree carried `examples/api_server/moon.mod` pinning
>   `riantr/moonbit_doubleML@0.164.26` while the library at that tag was
>   `0.164.27` -- the exact defect round 31 was created to eliminate.  The
>   checks were not wrong: the round-31 pin verifier READ THE WORKING TREE,
>   and on disk the manifest was correct.  The COMMIT captured the INDEX,
>   and the index still held round 32's blob, because the `git add` list
>   for that release was HAND-WRITTEN and had missed the file.  The tree
>   that was tested and the tree that were released were DIFFERENT TREES.
>
>   Round 31's own staging script derives its list from `git status
>   --porcelain`, so it cannot miss a file; round 33 stopped using it.  That
>   is the regression.  The tag is not moved, and never will be: a tag is
>   never reused.  The branch is repaired, and v0.164.28 carries the
>   corrected manifest.
>
>   The new check `_verify/_verify_release_tree_1650.py` runs **36** checks
>   over the tree at a REF rather than the files on disk.  Its default is
>   HEAD -- the tree the registry was last given -- and the release
>   procedure runs it against the new commit BEFORE the tag is made.  What
>   it checks at that ref: the library's version is readable; every example
>   manifest pins THAT version; every other bump site carries that version
>   and names no other library version; the two README copies are
>   byte-identical; and the README names that version.  The site set is
>   DERIVED from the bump script's own `EDITS` table -- "every place the
>   version lives" is a NAMED set, not a guess -- and the manifests are
>   derived from the tree itself.
>
>   I3 also grew: the small-n passage's INTEGER measurements were left out
>   because a bare-integer scan also picks up file:line numbers such as
>   `149`.  The code-span convention removes the need for that exclusion --
>   a code span holding exactly one number is a measurement, so `-1381`,
>   `-648` and `172149` are figures while `double_ml_score_mixins.py:149`
>   is a citation.  All three are witnessed by the record the README cites,
>   and the figure set is now **15**.
>
>   `_verify/_dryrun_round34_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.  Each mechanism COMMITS its breakage, because a
>   verifier that reads a ref cannot see an uncommitted edit.
>
> * **Round 35.** The README's API promises and its source citations were
>   both unchecked, and one of each was wrong.
>
>   The API-snippet check matched only snippets written with the
>   `@moonbit_doubleML.` prefix -- **4** of the **10** constructors the README
>   states.  The other six were written unqualified or inside a fenced block,
>   and no check could see them.  That is how
>   `DoubleMLLPLR::new(data, alpha=1.5)` -- a parameter that does not exist --
>   survived until a reader found it by hand: the check's wording said "the
>   README's API snippets" while its extraction reached 40 % of them.  The
>   check now reaches every constructor, and asserts that it reached them all.
>
>   Nothing checked the README's source citations either.  The DID paragraph
>   cited `did.mbt:708` for "the observational DID score", and line 708 is
>   `let w_d = d_i / m_i`, which lives in the `else` branch opened at
>   `did.mbt:704` -- the **experimental** score.  The observational branch is
>   `did.mbt:659-689`, and its default form computes
>   `(D - m) / (p_hat * (1 - m))`, where `1 / m` appears **nowhere**: `m` is in
>   the numerator, and for a treated row the `m` dependence cancels.  The
>   README's explanation of why the DID family's OLS default is safe was
>   describing a branch the shipped default never runs.
>
>   Two smaller drifts travel with it.  "A bare `moon test` runs every declared
>   backend" is false: measured on the toolchain this release was cut with, a
>   bare run prints `[wasm]`, `[wasm-gc]` and `[native]` and reports
>   `no test entry found` for `js` -- 1117 js tests it never runs, which reads
>   as a false green.  And the RNG keys are 32-byte ChaCha8 keys compared
>   **byte-for-byte** (`validate_bitexact_with_python.py:377`), not IEEE-754
>   doubles, so "25 of the 25 bit-exact items and 6 / 6 RNG keys are IEEE-754
>   identical" was wrong about the keys.
>
>   The two checks are `_verify/_verify_api_snippets_1680.py` (**135**
>   checks -- every constructor the README states, every named argument
>   against the source's parameters and defaults, every positional argument's
>   name against the source's name at that position, every `LearnerDispatch`
>   function it names, and the API reference's accessor promises) and
>   `_verify/_verify_citations_1650.py` (**45** checks -- C1: the cited range
>   must carry the token the sentence claims; C2: a citation that names a
>   configuration must sit in the branch that configuration selects, and a
>   doc-comment citation must NAME it).  The configurations C2 knows about are
>   DERIVED from the source's own `score == "..."` comparisons, not listed.
>
>   *That checker was replaced.*  The `file:line` checker this entry describes
>   was REWRITTEN in v0.164.33: the same file,
>   `_verify/_verify_citations_1650.py`, is now the PUBLISHER-record checker
>   described in round 39, and it makes **11** checks and asks a different
>   question.  The **45** above, and round 30's **103** citations in **40**
>   files, its **266** upstream citations and its fixed **108**, are what that
>   checker measured THEN; nothing in the tree measures them today, and a
>   reader who went looking for C1 and C2 in the file would not find them.
>
>   `_verify/_dryrun_round35_1650.py` breaks each of the seven mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.
>
> * **Round 36.** The README's NEGATIVE claims -- the whole "Not covered, so
>   not claimed" section -- were only HALF checked, and one of them OVERSTATED
>   the limit it described.
>
>   Round 22's `_verify/_verify_test_verification_1650.py` already re-derives
>   the absence claims: that the `mutation` and `fuzz` checks run in no CI
>   workflow, that the `coverage` check is a proxy and not instrumented line
>   coverage, that the fuzz harness ignores its seed argument, that the
>   mutation battery is three mutants on one kernel, that the two declared
>   `moon.mod` dependencies are imported by nothing, and that no CI step
>   invokes a dependency-vulnerability scanner.  What it could not see was the
>   SIZE of the thing the limit was about.  It checked that the seed argument
>   is ignored, and stopped there -- so the README was free to say the
>   consequence was "a re-run of one case, not a fuzz", and the check stayed
>   green.
>
>   One invocation is **11 surfaces at 300 trials each**: the harness's own
>   banner prints "300 trials per surface", and
>   `_verify/LPLR_GATE_BLINDNESS_1680.md` records "ALL 11 SURFACES PASSED".
>   So each invocation is a real property-based run, and what the check
>   repeats is that ONE run, because the seed ARGUMENT is ignored.  The limit
>   is the missing seed sweep, not a missing fuzzer -- and "not a fuzz"
>   contradicted the README's own Examples table, which calls the same binary
>   "Random-property fuzz harness across 11 surfaces".  The QA `fuzz` check's
>   evidence carried the same overstatement; it now reports the scale it
>   measured, derived from the harness source so it cannot rot.
>
>   The new check `_verify/_verify_not_covered_1650.py` (**52** checks) closes
>   the other half.  It measures the harness's scale, requires the README to
>   name it, and fails if the README or the check's evidence calls a fuzz run
>   "one case".  It also decides "does CI run this check?" by the runner's OWN
>   selection rule -- selected AND (scope is not `full` OR `--full` was
>   passed) -- read out of the workflow YAML, where round 22's check greps
>   the workflows for the check's ID.  That grep has a hole: a workflow that
>   selects the full scope without naming any ID would run the `fuzz` check,
>   and the grep would still report "no workflow runs it".  The
>   `dependencies` check is CALLED rather than re-implemented, and the claims
>   are matched against a whitespace-normalised copy of the document, because
>   a hard-wrapped README breaks a raw substring match.
>
>   The section's lead-in repeated the heading above it word for word, and the
>   "Still" in it asserted a continuity no document supports; it is gone.
>
>   `_verify/_dryrun_round36_1650.py` breaks each of the **12** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **18** failures.
>
> * **Round 37.** The README's API PROMISES were checked against the tree
>   for the first time, and **two** of them were false; and the tracked
>   verifier contract was not SELF-CONTAINED, so a green suite was a
>   statement about one working directory rather than about the repository.
>
>   *The two document defects.*  The API reference said "every estimator's
>   `new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
>   optionals".  Measured by the parameter's TYPE -- not its name, which
>   is how `ml_pi` was missed -- the **22** estimators take **8** distinct
>   argument sets: `ml_g` / `ml_m` on **11**, `ml_l` / `ml_m` on
>   `DoubleMLPQ` and `DoubleMLQTE`, `ml_g` / `ml_m` / `ml_r` on
>   `DoubleMLIIVM`, `ml_g` / `ml_m` / `ml_pi` on `DoubleMLSSM`, `ml_g`
>   alone on `DoubleMLBLP` and `DoubleMLRDD`, `learner_l` / `learner_m`
>   on `DoubleMLPLR`, `learner` on `DoubleMLPLIV` and `DoubleMLPLPR`,
>   and NO learner at all on `DoubleMLLPQ` and `DoubleMLPolicyTree`.  The
>   same paragraph's "Default is `LearnerDispatch::linear_regression()`
>   (OLS)" is true for `ml_g` everywhere and FALSE for `ml_m` on the
>   **seven** structs migrated to a classifier -- which the README itself
>   names further down, so the page contradicted itself.  The promise is
>   now the table of argument sets, derived from the source.
>
>   The Status table's sandwich-variance row said "Introduced v0.89.0".
>   The CHANGELOG's own headings say **v0.79.0** introduced the family
>   (HC0-HC3 + cluster) on `DoubleMLIRM` and `DoubleMLPLR`, v0.86.0 and
>   v0.87.0 extended it, and v0.89.0 was ONE step of that extension
>   (10 -> 12 of 22).  The row's counts were right -- **15** scalar,
>   **4** per-cell, **3** with none of that API -- so the defect was in
>   the version literal, which rots silently because nothing else on the
>   page repeats it.  The row also said "**3** expose none", true of the
>   sandwich API and misleading about robustness: `DoubleMLBLP` and
>   `DoubleMLRDD` expose a heteroskedasticity-robust `hac_se` under their
>   own name (v0.96.0 and v0.97.0), and the README did not mention
>   `hac_se` AT ALL.  A limit that is understated is as false as one that
>   is overstated.
>
>   The API reference said "each DID variant takes its own data type".  It
>   does not: `DoubleMLDIDCS`, `DoubleMLDIDCSBinary` and `DoubleMLDIDMulti`
>   all take `DoubleMLDIDCSData`.  The sentence now names the four types
>   the DID family actually takes.
>
>   *The contract was not self-contained.*  The local suite is the tracked
>   `_verify/` contract, and it was measured in a FRESH CLONE: **3** of the
>   tracked verifiers FAILED there, and **15** of them located their tree by
>   the ABSOLUTE path of the working copy -- in a clone they read the
>   ORIGINAL tree, so they went green for the wrong reason.  Two verifiers
>   also depended on files git does not track
>   (`_verify/_probe_ops_1640.mbt`, `_verify/_qa_fast_1639.json`), and two
>   more FAILED on a clone because they check a downloaded third-party tree
>   that a clone does not have, with no notion of "the subject is not here".
>
>   The fixes: **61** tracked verifiers now derive their root from
>   `__file__`; the two upstream-dependent verifiers SKIP with a reason
>   when the vendored tree is absent (still counted, still visible); the
>   commands verifier builds the example before it checks the built path;
>   the fmt gate copies the package OUTSIDE the workspace and WARMS the
>   copy before each arm mangles it -- the copy's deleted `_build` left the
>   toolchain's format task "up to date" with its output missing, and the
>   warm-up itself runs `moon fmt`, so warming a MANGLED copy would format
>   it and the check would exit 0 for the wrong reason; the
>   upstream-records verifier resolves a cited path against the REPOSITORY
>   ROOT -- it used to resolve against the PARENT of the checkout, so its
>   green depended on the checkout's directory NAME -- treats a citation
>   to a path the repository IGNORES as the LOCAL promise it is, and skips
>   with a reason; and the two missing files are now TRACKED.  After the
>   fixes the whole tracked contract runs GREEN in a fresh clone.
>
>   The new check `_verify/_verify_contract_selfcontained_1650.py` holds
>   the contract to it: no tracked verifier may name an absolute path,
>   every tracked verifier's root must resolve to THIS repository, every
>   repository-relative file a tracked verifier READS must be a TRACKED
>   file, and a verifier over a downloaded tree must have a SKIP path.
>
>   The three checks are `_verify/_verify_api_promises_1650.py`
>   (**42** checks), the extended
>   `_verify/_verify_sandwich_coverage_1680.py` (**16** checks) and
>   `_verify/_verify_contract_selfcontained_1650.py` (**8** checks).
>   `_verify/_dryrun_round37_1650.py` breaks each of the **16**
>   mechanisms one at a time and requires the failure count to GROW at
>   every step, and it ends at **23** failures.
>
> * **Round 38.** The README named things the TREE DOES NOT HAVE -- a file
>   that never existed, a capability the package does not export, a rule its
>   own manifest breaks, a measurement stated more strongly than it was
>   measured -- and the tree's own validator count was **FORTY-TWO** releases
>   stale.
>
>   *The four document defects.*  The Project-layout block named
>   `moonbit_doubleML.mbt` -- "the main re-export file (the import surface)".
>   There is no such file: `git log --all --diff-filter=AD -- '*moonbit_doubleML.mbt'`
>   is EMPTY, so it never existed in this repository.  The layout now names
>   `moon.pkg`, the package's real interface file.
>
>   The API bullet promised "optional JSON in/out for native / wasm-gc / wasm
>   / js backends".  The library exports NO JSON API: with comments and
>   docstrings stripped, no production file in the package mentions a JSON
>   type, a `to_json` or a `from_json`.  The JSON that exists belongs to
>   `examples/api_server/`, which does its own request and response encoding.
>   The bullet now says exactly that.
>
>   The same bullet asserted the dependency rule is met -- "only
>   `moonbitlang/*` official packages" -- while `moonbit_doubleML/moon.mod`
>   declares `moonbit-community/sqlite3@0.2.3`, a non-official package that
>   nothing imports.  The README's own Dependency-rule section already said
>   "the rule is not met, by one line", so the page contradicted itself.  The
>   bullet now discloses the one declared line that does not meet the rule,
>   and keeps the claim that IS true -- the library's runtime supply chain is
>   `moonbitlang/core` only.
>
>   The hazard table's QTE row said the OLS arm was "frozen at `-1.583` for
>   tau `0.50`-`0.90`".  The release that measured it (v0.139.0) recorded FIVE
>   taus and found the freeze at THREE of them (`0.50` / `0.75` / `0.90`); at
>   `0.10` and `0.25` it was not frozen.  A hyphen reads as a continuous
>   interval the evidence does not support.  The row now names the three
>   measured taus.
>
>   *The count that rotted.*  `_verify/run_all_validators.py` said it runs
>   "all 23 validate_*.py", and the tracked capture
>   `_verify/validate_results.txt` said "Total: 23, PASS: 23".  The capture's
>   blob has not changed since **v0.68.0**, when the tree really did hold 23
>   validators; the twenty-fourth landed with **v0.163.0**, and the number
>   stayed wrong through **FORTY-TWO** releases (v0.163.0 -> v0.164.31).  A
>   claim no check re-derives is a claim that can rot unnoticed -- the same
>   disease as a layout naming a file that was never there.  The runner's
>   docstring now states the RULE (it runs every `validate_*.py` in the tree)
>   and lets the script derive the number, and the capture was regenerated by
>   re-running it: **Total: 24, PASS: 24, FAIL: 0**.
>
>   *What could not see a count.*  `_verify/_verify_count_referents_1650.py`
>   scanned for counts written as a WORD, at most twelve, beside one of
>   twelve nouns -- so it could not see "**22** estimators", the README's most
>   repeated count, nor "four data types", nor "24 Python reference scripts".
>   A registry that cannot SEE a claim cannot own it, and an unowned count
>   rots.  The scan now runs in three forms (the word form, the word form past
>   twelve, and the DIGIT form), the ARTEFACT vocabulary covers data types,
>   files, spellings, classes, packages, implementations, modes, jobs,
>   surfaces, scripts, binaries, examples, tests and arguments, and a new
>   section G derives the inventory's own counts FROM THE TREE -- the 22
>   estimator structs, the 19 files that hold one, the 220 `.mbt` files, the
>   129 blackbox, the 26 whitebox and the 24 Python reference scripts.  A
>   digit count's intervening tokens may not contain a digit, so the scan
>   cannot bridge over a comma and read "65 production, 129 blackbox test" as
>   a count of 65.
>
>   The new check `_verify/_verify_package_claims_1650.py` (**48** checks)
>   holds the README to what the package IS and PROVIDES: every file the
>   layout names must be a TRACKED file; the JSON surface is derived from the
>   package's sources with comments and docstrings stripped, because a JSON
>   mention in a COMMENT is not a JSON API; the dependency set comes from
>   `moon.mod`'s import block with comments stripped, so the manifest's
>   commented EXAMPLE (`moonbitlang/x`) is not counted as a dependency; and
>   the QTE row's taus must equal the CHANGELOG's own v0.139.0 taus, as a
>   sampled set and not as a range.
>
>   `_verify/_dryrun_round38_1650.py` breaks each of the **10** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **16** failures.  It caught three defects in its own construction:
>   the mechanisms are CUMULATIVE, so a mechanism that patches a passage an
>   earlier mechanism already rewrote must patch the text as it now stands; a
>   probe file that did not match the pattern the registry derives its count
>   from would have contributed NOTHING; and the counter counted a bare
>   `*** FAIL ***` section HEADER as a failure, which no verifier ever
>   reported -- the count has to equal the number the verifiers state in their
>   own `N checks, M failed` summaries, because that is the number the
>   CHANGELOG publishes.
>
> * **Round 39.** A SECOND USER-FACING DOCUMENT had never been audited, and
>   TWO of the README's claims had no check that could see them.
>
>   *The second document.*  `skills/moonbit_doubleML.md` is what a coding
>   agent READS before writing code against this library, so every claim in
>   it is a promise the tree has to keep -- exactly like the README's.  No
>   check read it at all, and the rot showed immediately: the skill quoted
>   the api_server's declared library pin as
>
>   > the library pin `0.52.0`
>
>   while `examples/api_server/moon.mod` declared 0.164.32.  That is the SAME
>   rot the two tutorials had -- fixed in v0.164.3, when the bump script
>   gained sites 5 and 6 for exactly this reason -- in the same shape, missed
>   for **132** releases because the file is a DOCUMENT and nothing read it.
>   The skill is now bump site **9**, and `_verify/_verify_skill_claims_1650.py`
>   (**58** checks) audits it: its pin, the **26** whitebox files and the
>   **169** test cases in them, the **21** driver binaries and the `main.mbt`
>   each one carries, the **24** cross-validators and the three repo-level
>   harnesses the glob does not pick up, the **9** scripts that take their
>   reference from the upstream wheel, the **11** learner variants by NAME,
>   the **16** estimators that expose all four accessors and the six that do
>   not, the **19** estimator files and the three that hold two structs, the
>   **17** DGP modules and the **35** files in all, and every concrete file
>   the skill names.  Every one of those numbers was RIGHT; only the pin had
>   rotted.
>
>   *A citation no check could see.*  The honesty section cited "Athey &
>   Imbens (2016, PNAS 113(27):7353-7358)".  The publisher's own deposited
>   record for the DOI gives the page range as **7353-7360**, and OpenAlex
>   agrees.  The authors, the year, the journal, the volume and the issue
>   were all right, and the SUBSTANCE the README credits is right -- only
>   the last two digits of the range were wrong.  A reader who looked the
>   paper up would have found the citation wrong and the claim right, which
>   is the worst of both.  No in-tree check can see a literature citation,
>   which is why it survived thirty-eight rounds;
>   `_verify/_verify_citations_1650.py` (**11** checks) now resolves each
>   citation against the PUBLISHER's record -- Crossref for the two journal
>   articles, arXiv for the preprint -- and compares the year, the volume,
>   the issue and the page range field by field.  When the publisher cannot
>   be reached the check SKIPS with a reason: an unreachable publisher is
>   not a wrong citation, and a contract that turns a network outage into a
>   red build teaches its reader to ignore it.
>
>   *An order that reads as a claim.*  The sandwich-variance row said
>   "`DoubleMLBLP` and `DoubleMLRDD` do expose a heteroskedasticity-robust
>   `hac_se` under their own name (v0.96.0 / v0.97.0)".  Read positionally
>   -- the way this document pairs names with versions everywhere else --
>   that asserts BLP = v0.96.0 and RDD = v0.97.0, and BOTH are false:
>   `rdd.mbt` marks its `hac_se` "v0.96.0+" and `blp_policy.mbt` marks its
>   own "v0.97.0+", and the CHANGELOG's own headings agree.  The SET of two
>   versions was right, so the defect was the ORDER -- and an order that
>   reads as a claim is a claim.
>   `_verify/_verify_sandwich_coverage_1680.py` (now **20** checks) derives
>   each `hac_se` version from the SOURCE's own doc-comment, cross-checks it
>   against the CHANGELOG's heading, and then requires the table to PAIR
>   them.
>
>   Two smaller gaps closed with them.  The README's "the library imports
>   nothing outside `moonbitlang/core`" had NO check behind it; the library's
>   sources declare no import of their own and the package's whole import
>   surface is `moon.pkg`'s `moonbitlang/core/*` block, and that is now
>   asserted.  And round 38's layout check matched only `.mbt` / `.pkg` /
>   `.mod`, so every DIRECTORY the Project-layout block names -- and
>   `moon.work`, `AGENTS.md` and `skills/moonbit_doubleML.md` -- went
>   unchecked; a path in prose is a promise whether or not it ends in an
>   extension, and all **24** of them are now checked.
>
>   `_verify/_dryrun_round39_1650.py` breaks each of the **8** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **13** failures.  It needs the network, because one of the
>   mechanisms is exercised by the citation check; the pre-flight refuses to
>   run without the publisher rather than measuring nothing.
>
>   *The toolchain moved under the release.*  The local `moon` went from
>   `0.1.20261016` to `0.1.20261023` while this release was being cut, and the
>   README's Toolchain row is checked against the INSTALLED toolchain -- so the
>   row, and every claim that names a toolchain, had to be RE-DERIVED rather
>   than re-labelled.  All four held: a bare `moon test` still prints
>   `Total tests: 0` for `wasm` and `native` and reports "no test entry
>   found" for `js`; `@std/env`, `@std/fs`, `@std/io` and `@std/process` still
>   do not resolve and the builtin `read_file` still does not exist (error
>   4021); and the operator bit-exactness table is unchanged, because
>   `_verify/_verify_op_table_1640.py` re-measures it on whatever toolchain is
>   installed NOW.  ONE claim did not survive the move: `train` was a hard
>   error on `moon 0.1.20261016` and is NOT reserved on `moon 0.1.20261023` --
>   it compiles as a local and as a field -- so the agent skill's "all are
>   reserved in current MoonBit" was corrected to say which ones are and which
>   one moved.
>
> * **Round 40.** The LEDGER nobody read.
>
>   *The last stale pin.*  `doc/moon.mod` -- the DOC PROJECT's own manifest --
>   named the library at **0.52.0**, and it was the LAST file in the tree still
>   carrying that literal.  The round-31 sweep fixed all 21 example manifests
>   and the round-39 sweep fixed the agent skill; neither of them read this
>   file, because it is a THIRD kind of file.  In-tree the pin is inert --
>   `doc` is a member of `moon.work`, so the workspace member wins and the six
>   tutorials build against the current library -- and outside the tree it is
>   the only thing that decides what gets installed.  It is now bump site **10**
>   of `_verify/_bump_1636.py`, so it moves with the release, and the
>   release-tree check holds it to the version like every other site.
>
>   *Four numbers in this banner that no check owned.*  This banner publishes
>   a count for the checks it names, and every one of those numbers is a claim
>   about the TREE -- but nothing could see them: the CHANGELOG publishes its
>   own counts and the checks that publish one assert it against their own
>   run, while the BANNER's numbers were asserted by nobody.  Four were false:
>   `_verify/_verify_measurements_1650.py` published **66** and makes **70**;
>   `_verify/_verify_release_tree_1650.py` published **34** and makes **36**;
>   `_verify/_verify_package_claims_1650.py` published **19** and makes **48**;
>   and `_verify/_verify_score_argument_1650.py` published **131** and makes
>   **135**.  The third of the four is the one worth recording: **19** was
>   never true -- that check has run more checks than it ever published, and
>   it has done so since the day it was written.
>
>   The new check `_verify/_verify_ledger_counts_1650.py` (**32** checks) owns
>   the class.  It reads the counts this banner publishes, RUNS each check it
>   names, and requires the published number to be the number that check makes
>   on this tree; and it requires the CHANGELOG's publication of the same
>   count to agree with the banner's, because the two documents are read side
>   by side and must not contradict each other.  The count is MEASURED, not
>   read: a check's count is what its checks add up to, so no literal in the
>   source can stand in for it.
>
>   *Eight sentences that were false.*  A fresh-eyes audit of the README, the
>   agent skill and the six tutorials found eight claims that were FALSE, and
>   not one of them was a number that had rotted: they were prose asserting
>   something the tree does not do, and a sentence can only be rewritten.
>   The agent skill said all 16 CLI-style demos "print true-vs-estimated
>   theta and a 95% CI" -- **14** of the 16 print a true value and **11**
>   print a CI, and the README had said so for releases.  The estimators
>   tutorial said the port has **9** `score` parameters and told the reader
>   to pass one to `fit_cluster(...)`: there are **8**, at 7 estimators, and
>   `fit_cluster` is a PRIVATE dispatch target, so a reader who followed the
>   sentence got "Type DoubleMLPLR has no method fit_cluster".  The same
>   tutorial gave `DoubleMLDIDMulti` a panel-form `DoubleMLDIDData`; it
>   takes `DoubleMLDIDCSData`.  The README pointed at "the full curl recipe"
>   in a file whose recipe is a PowerShell one, and offered a
>   `moonrun --port 4000` invocation that moonrun REJECTS and that the
>   service ignores anyway -- its listen port is hard-coded.  The estimators
>   tutorial also promised a note about upstream's `__all__` that the
>   package README does not carry.  And the DGP tutorial said the panel and
>   DID DGPs return `DoubleMLPanelData` / `DoubleMLDIDCSData` and carry
>   `t` / `g` / `id` accessors: they return `DidCsData`, `DidMultiData` and
>   `PlprData`, the panel one carries no `t` / `g` / `id` at all, and the
>   worked example it pointed at held no LPLR test.
>
>   The new check `_verify/_verify_doc_claims_1650.py` (**32** checks)
>   derives every one of those from the SOURCE: the demo split from the
>   record the measuring verifier writes, the `score` parameters from their
>   signatures with the parentheses BALANCED -- a `[^)]*` matcher cuts a
>   signature short at the first ")" and loses one of the eight -- the DGP
>   factories' return types and accessors, the api_server's port, and the
>   test names in the files the tutorials cite.
>
>   `_verify/_dryrun_round40_1650.py` breaks each of the **5** mechanisms one
>   at a time and requires the failure count to GROW at every step, and it
>   ends at **7** failures.  Three of the mechanisms break this banner's
>   own numbers, one breaks the pin and one breaks a tutorial's count, so
>   the classes are proved from both sides.
>
> * **Round 41.** The count that moved with the network.
>
>   *A number that was true only while a publisher answered.*  Two
>   fresh-eyes audits -- one for the numbers, one for the promises --
>   independently found the same defect.  The citation check
>   `_verify/_verify_citations_1650.py` publishes **11** checks, and it made
>   ten of them whenever arXiv was unreachable, because the skip that stood
>   in for the preprint's two checks was ONE skip.  The check that owns this
>   banner's counts compares the published number with the number the check
>   MAKES, so a publisher's rate limit turned the whole tracked contract
>   red -- and the release's own claim, "57 passed / 0 failed", was true
>   only while the network was up.  One auditor watched arXiv answer 429
>   and watched the contract fail; the other read the same thing off two
>   runs of the same script.
>
>   A skip now stands for EXACTLY the check it replaces: one per field that
>   could not be compared, and one per arXiv check.  The count is the
>   number of checks DEFINED, which is a property of the file and not of
>   the network -- the round-29 precedent, applied to the reachability of a
>   third party rather than to the shape of the tree.  Measured both ways:
>   `_verify/_verify_citations_1650.py` makes **11** checks with the
>   publishers reachable, and **11** with every request failing.
>
>   *A number this banner published that no check could see.*  Round 40's
>   entry records its four corrections in a shape with no "checks" word in
>   it -- a published count and the count the check actually makes -- so
>   the check that reads this banner's counts never saw it.  The
>   score-argument one was FALSE: `_verify/_verify_score_argument_1650.py`
>   makes **135** checks, and the banner said **131**.
>   `_verify/_verify_ledger_counts_1650.py` (**34** checks) reads that shape
>   now, and its live half is the count the check makes; the other half is
>   history, the way "v0.164.21's entry said ... runs **127**" is history in
>   the CHANGELOG.  A prose claim that no check can see is a claim that rots
>   in silence, and silence is what let this one rot.
>
>   *One checker, three counts, and a file that was rewritten.*  This banner
>   published **108** for the citation check in round 30, **45** in round
>   35 and **11** in round 39 -- and the file was REWRITTEN in v0.164.33,
>   so the rules round 35 describes (C1 and C2) are not in it any more.  A
>   reader who went looking for them would not find them.  Round 30's entry
>   now says what it measured then, and round 35's carries the note.
>
>   *The upstream roster was 17, and upstream has 21.*  Round 29's entry
>   published "upstream 0.11.4's 17 estimator classes", and the check that
>   derived it matched `^class (DoubleML\w+)\(` -- which needs BOTH the
>   prefix and the parentheses, and upstream declares `DoubleMLBLP`,
>   `DoubleMLPolicyTree` and `RDFlex` without them.  The number was wrong,
>   and it was wrong in a way that AGREED with the docstring it checked:
>   the `cf` default of `0.03` really does reach **17** classes, and that
>   is a different seventeen.  A check that agrees with a document for the
>   wrong reason is not a check.  The count is derived from the AST now --
>   upstream's class graph, walked -- and from the port's own provenance
>   record, which names the upstream classes the port ports.  The
>   `cvar.mbt` docstring says "17 of its 21 estimator classes", and
>   `_verify/_verify_docstring_counts_1650.py` (**76** checks) measures both
>   numbers and names the four upstream classes with no
>   `sensitivity_analysis` at all.  The tracked record that had published
>   the reach as **16** -- and had said "17 is not the measured number" --
>   was corrected in place, with the re-measurement that shows why.
>
>   *A workflow that described a layout the tree no longer had.*  The
>   nightly workflow said the package was "flat-layout (no moon.work)" and
>   that it checked "the package root directly rather than iterating over
>   workspace members".  The REPOSITORY root carries the workspace -- the
>   library, `doc/` and the examples -- and `moon check` resolves UP to
>   that root from any directory inside it, so the step checks every
>   member.  Measured: the same task list from the repository root and from
>   the package directory.  `_verify/_verify_layout_1680.py` owns the claim
>   now.
>
>   *Two paths in prose that pointed at nothing.*  The api_server's README
>   named two files under `.archived/` that exist in a local working tree
>   and are git-ignored, so a clone does not have them; it says so now.  And
>   `doc/moon.mod` -- the DOC PROJECT's manifest -- declared
>   `readme = "README.md"`, a file that does not exist; the doc project
>   has the landing page its manifest promises now.
>
> * **Round 42.** The promises the tree could not keep.
>
>   *A licence that granted one thing and claimed another.*  The README
>   said MIT, the manifest declared MIT, and mooncakes.io published MIT --
>   but the root `LICENSE` was the stock APACHE-2.0 text: 202 lines, with
>   its `Copyright [yyyy] [name of copyright owner]` placeholder unfilled,
>   and untouched since the initial commit.  `CHANGELOG.md`'s v0.60.0
>   entry records the intent -- the licence was rewritten to MIT and the
>   MANIFEST was fixed to match, but the licence TEXT was never rewritten.
>   So a reader who downloaded the repository was handed Apache-2.0 while
>   every document told them MIT, and 22 manifests still carried the
>   pre-v0.60.0 default.  Both LICENSE files carry MIT now, and every
>   manifest declares it.  `_verify/_verify_license_1650.py` (**11**
>   checks) owns the class, and its count is fixed against the network as
>   well as the tree.
>
>   *A version number about somebody else's repository.*  The "Used By"
>   section said pyroduct's cross-check ran against `riantr/moonbit_doubleML`
>   "v0.163.3 (its current pin)".  Pyroduct bumps its pins on its own
>   schedule: by the time this README shipped, its `moon.mod` imported
>   `0.164.34`, and the literal `0.163.3` survived only inside a comment
>   in pyroduct's own manifest.  A number this repository does not control
>   must not be published as one it does, so the literal is gone and the
>   figures -- `n = 400`, `theta = 1.5`, the two deltas -- stay.
>   `_verify/_verify_package_claims_1650.py` (**51** checks) owns it.
>
>   *A routing instruction that did not route.*  The api_server's README
>   said new routes go in the `routes` constant, but `/ping` is not in it:
>   `/ping` is answered before the body is read and before the router
>   runs, and it is one of the five endpoints the same README tabulates.
>   `_verify/_verify_doc_claims_1650.py` (**43** checks) owns that, and
>   with it the introduction's example size -- the fenced block's own
>   height, which is 35 lines and not the 30 the text used to say -- and
>   the source comment's own wasm recipe, which named the wrong build
>   directory, dropped the release profile and passed a `--port` flag the
>   service does not read.
>
>   *A verification claim that failed on a clone.*  The README published
>   "all four mutations killed".  The mutation battery matches LITERAL
>   newlines in `examples/bitexact/main.mbt`, so in a CRLF working tree two
>   of its four mutations matched nothing: the battery skipped them and
>   exited 1.  The release machine carried a local `core.autocrlf=false`,
>   which is not part of the tracked tree, so only the machine that cut the
>   release ever saw the claim hold.  The repository now pins its own line
>   endings in a root `.gitattributes`, and the battery matches whichever
>   endings the file has.  Measured: four of four killed in an LF tree and
>   four of four killed in a CRLF clone.  `_verify/_verify_layout_1680.py`
>   owns the file.
>
>   *A class of pointers that no check owned.*  The `file:line` checker was
>   rewritten in v0.164.33 into the publisher-record checker and nothing
>   took its place, so the in-repo pointers in the README, the skill, the
>   tutorials, the api_server README and the CI comments were owned by
>   nothing at all.  `_verify/_verify_file_line_refs_1650.py` (**60**
>   checks) owns them now: every pointer's file must exist and be
>   tracked, its line must be inside the file, and the block it sits in
>   must name something the target file carries.
>
>   *And the count that moved with the HOST.*  The first run of that check
>   made 116 checks in the working tree and 60 in a fresh clone, and the
>   fresh clone was right.  The root `README.md` is a SYMLINK to
>   `README.mbt.md`: a checkout that can materialise a symlink reads the
>   same document twice, and a Windows clone -- where git writes the link
>   target as a one-line stub -- reads it once.  A check that counted a
>   document by PATH would make its own count depend on the host.  The
>   document set is deduped by CONTENT now, and the check makes the same
>   number of checks in both environments.
>
>   *The ledger that reads this banner grew by two checks*, because the
>   contract has two more members: `_verify/_verify_ledger_counts_1650.py`
>   (**38** checks) now.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round42_1650.py` breaks ONE promise -- the licence text,
>   a manifest's licence, a pointer to a file that is not there, a pointer
>   past the end of its file, the routing instruction's exception, the
>   introduction's example size, the "Used By" section's pin, the
>   repository's own line endings -- and the failure count must GROW at
>   every step.  The run ends at **16** failures.

>
> * **Round 43.** The licence the tree did not close, and the code that did
>   not compile.
>
>   *A licence that granted one thing and claimed another -- again.*  Round 42
>   rewrote TWO of the seventeen LICENSE files, and the v0.164.36 entry
>   announced the class closed: "Both LICENSE files now carry MIT".  The tree
>   has SEVENTEEN tracked LICENSE files, and FIFTEEN of them still carried the
>   stock Apache-2.0 text -- each one beside a `moon.mod` that declared
>   `license = "MIT"`.  Six package directories shipped no LICENSE at all.
>   The check that owned the class read two files, so it could not fail on the
>   other fifteen: it was written to match the fix that had been made, not to
>   match the class of defect.  Every licence file in the tree is
>   byte-identical to the root MIT text now, and every package directory that
>   has a manifest is covered by one.  `_verify/_verify_license_files_1650.py`
>   (**6** checks) owns the class, and its count is fixed against the tree.
>
>   *Two code blocks the reader could not compile.*  The published README is a
>   document a reader COPIES from, and two of its fenced `moonbit` blocks did
>   not compile.  The first assigned to `ml_m`, which is not a variable -- it
>   is an optional NAMED PARAMETER of eight estimators' constructors -- so the
>   line does not compile at all, and it was written in the LIBRARY's
>   namespace rather than the reader's.  The second passed the Quick Start's
>   `DoubleMLData` to `DoubleMLLPLR::new`, which takes a `DoubleMLBinaryData`
>   -- LPLR's outcome is BINARY:
>
> >     Expr Type Mismatch
> >     has type : @riantr/moonbit_doubleML.DoubleMLData
> >     wanted   : @riantr/moonbit_doubleML.DoubleMLBinaryData
>
>   The README's own verifier could not see either: it checks the NAMES of a
>   call's arguments, and a type mismatch is not a name.  Both blocks are
>   rewritten into the reader's namespace, and
>   `_verify/_verify_readme_snippets_1650.py` (**7** checks) COMPILES them --
>   EACH in its own probe, against the LOCAL library, with a preamble that
>   supplies the context the fragments assume.  One probe with every block in
>   it proves only that AT LEAST ONE block compiles: the compiler stops at
>   the first error, so a broken block hides the ones after it.  CI runs it.
>
>   *A rule with a false positive.*  The API-snippets check compares a named
>   argument's value with the source's DEFAULT, because the README's
>   convention is that a constructor call it states shows the defaults.  Round
>   43's "pass a classifier explicitly" snippet deliberately passes a
>   NON-default learner, which the rule flagged.  The rule now applies to
>   LITERALS only: an expression is a choice, not a stated default.
>   `_verify/_verify_api_snippets_1680.py` published **135** and makes
>   **139**.
>
>   *Two documents that disagreed.*  `AGENTS.md` said the api_server's
>   `main_test.mbt` "is currently empty"; the api_server's own README said
>   there is **no** `main_test.mbt`, and the file does not exist.  And the
>   agent skill's anti-pattern list said `train` was "reserved in current
>   MoonBit" -- in the same paragraph that said it was not.
>
>   *The ledger that reads this banner grew by six checks*, because this
>   banner now publishes a count for three more checks than it did -- and the
>   ledger makes one check in each of its two live sections for every check
>   the banner names, so a new name costs two.
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) now.
>
>   *A sweep of the tree's own dry-runs.*  SIXTEEN of the THIRTY had stopped
>   biting, and the causes were three classes, all of them mechanical: a
>   mechanism's ANCHOR had moved, a CLASS had moved to a different verifier,
>   and a PUBLISHED COUNT had gone stale.  Three drivers read the FIRST
>   published count in the whole CHANGELOG instead of their own, so each
>   compared its measurement against a number that belonged to somebody
>   else's dry-run; every driver now reads the count from the BULLET that
>   names it, and one entry can carry several drivers' counts.
>
>   `_verify/_verify_dryrun_teeth_1650.py` (**13** checks) owns the class now.
>   It SIMULATES every driver's mechanisms in source order -- they are
>   CUMULATIVE, so a mechanism may patch the text an earlier mechanism
>   produced -- and it holds every anchor live in the tree, every patched
>   file tracked, every verifier a driver names still in the tree, every
>   driver's counter able to SEE its verifiers' failure markers, and the
>   CHANGELOG's published count and this banner's to agree.
>
>   *And it holds the OWNER and the CHECKER to the same number.*  The
>   sentence that carries a published count is hard-WRAPPED, so a reader that
>   matches it with literal spaces reads an OLDER entry's number instead: four
>   drivers were comparing themselves against somebody else's count, one read
>   nothing at all, and the checker here reported that six drivers published
>   no count -- two readers, each certain, both wrong, and nothing comparing
>   them.  Every driver now reads its own number out of a
>   whitespace-collapsed bullet, every driver that reads the banner finds a
>   count there, and this checker runs the driver's own lookup and requires
>   the two to agree.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round43_1650.py` breaks ONE promise -- a licence text, a
>   missing licence, the README's `ml_m` block, the README's LPLR block, a new
>   block that does not compile, and the probe's resolution of the library --
>   and the failure count must GROW at every step.  The run ends at **8**
>   failures.
>
> * **Round 44.** The service that died on a bad request, and the documents
>   that promised something else.
>
>   *A malformed IRM request killed the whole service.*  `POST /fit/irm` with a
>   treatment vector that is not binary -- or is binary but leaves one arm
>   empty in a fold -- made the library ABORT (`require(train_d0.length() > 0)`,
>   `irm.mbt:378`).  A MoonBit panic is not catchable: `require` and `abort`
>   are panics rather than errors, so the `try/catch` around the handler could
>   not hold it and the PROCESS EXITED.  `/healthz` then refused connections,
>   so one bad request took the service down for every other caller.
>   `examples/api_server/main.mbt` now PRE-VALIDATES the split with the
>   library's own public `kfold` and `Fold::train_indices`, and answers **400**
>   instead of dying.  The api_server's QA check now asserts four cases: a
>   valid fit, a non-binary treatment, a fold without both groups, and a live
>   `/healthz` after each rejection.
>
>   *A dependency two versions behind.*  The api_server example pinned
>   `moonbitlang/async@0.20.3` while this README's own dependency rule says to
>   pin the latest published version (`0.22.5`) -- and the example is the only
>   thing in the tree that imports it at all.  It is on `0.22.5` now, and the
>   dependency table's note says what is actually true: the line is dead IN THE
>   LIBRARY, and the example imports the same package at the same pin.
>
>   *Five documents that promised something the tree does not do.*  The DID
>   bias was rendered as "~0.001" where the measured figure is `0.00050` -- a
>   2x overstatement of a number the same paragraph prints correctly two lines
>   later.  The layout block named `example/consumer_demo`, which is the
>   example's PACKAGE name, where a repository PATH was meant
>   (`examples/consumer_demo`).  A bare `moon test` does not run "three of the
>   four declared backends": it runs the suite on ONE of them (`wasm-gc`),
>   reports `Total tests: 0` for `wasm` and `native`, and never reports `js` at
>   all -- while `moon test --target js` runs 1117 of them.  The installation
>   guide told an installed CONSUMER to run the test suite and quoted the
>   repository's 1117, and a consumer that installs the package runs no tests
>   at all.  And the introduction's blanket rule -- "`ml_m` defaults to the
>   logistic classifier wherever the propensity enters the score as
>   `1 / m_hat`" -- is false for `DoubleMLIIVM`, which carries `1/m` and
>   `1/(1-m)` and still defaults `ml_m` to OLS.
>
>   *A finding that was wrong twice.*  Two independent audits reported that
>   `doc/006_python_check` mis-split the Python cross-check coverage, and BOTH were wrong.
>   A MUTATION settles a coverage claim: `DoubleMLQTE::fit` was broken, and the
>   validate family stayed GREEN -- so it does not gate the QTE estimator, and
>   the guide's **16** / **3** / **3** split is correct.  What the validate
>   script's own LABEL overstates is its coverage, not the guide's arithmetic.
>   `_verify/_verify_tutorial_claims_1650.py` already derives that map from
>   what each script CONSTRUCTS.
>
>   *One published count moved.*  The rule about `ml_m`'s default now has an
>   owner for the TUTORIAL as well as for the skill, and that owner derived
>   the tutorial's sentence from the SOURCE: the blanket rule the
>   introduction stated is false for `DoubleMLIIVM`, whose `ml_m` models the
>   INSTRUMENT's propensity and still defaults to OLS.
>   `_verify/_verify_score_argument_1650.py` published **135** and makes
>   **140**.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round44_1650.py` breaks ONE promise -- the layout's
>   path, the dependency table's note, the service sentence, the bare-`moon
>   test` sentence, doc/001's `ml_m` rule and doc/002's consumer count --
>   and the failure count must GROW at every step.  The run ends at **8**
>   failures.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 45.**  The service that died on ANOTHER bad request.
>
>   The v0.164.38 release added a pre-validation to `POST /fit/irm`, and its
>   CHANGELOG entry said the service "answers **400** instead of dying".  It
>   did -- for the two cases it enumerated.  For a third it still DIED, and
>   the panic was in the NEW validator: `require_irm_split` calls the
>   library's own `kfold`, and `kfold` aborts on `require(n_folds <= n_obs)`
>   (`kfold.mbt:442`) -- a PANIC, not a catchable error, so the process
>   exits and every later caller is refused.
>
>   MEASURED, not inferred: `POST /fit/irm` with one row and `n_folds = 2`
>   printed `precondition failed at kfold.mbt:442:5-442:30` and
>   `PanicError`; the client saw the connection reset, and `/healthz` then
>   answered "connection refused" instead of `{"status":"ok"}`.  `/fit/plr`
>   died the same way -- it calls the library too -- and so did `n_folds = 1`
>   and `n_rep = 0`, because the library `require`s `n_folds >= 2`,
>   `n_folds <= n_obs` and `n_rep >= 1` (`plr.mbt:106-108`,
>   `irm.mbt:121-123`).
>
>   The service now checks the SAME conditions first, in
>   `require_crossfit_params`, and `parse_fit_request` calls it -- so BOTH
>   fit handlers are covered, and no endpoint can reach a `require` with a
>   value the library will reject.  All five cases answer **400** and the
>   service stays up.  The api_server's QA check asserts them: the two from
>   v0.164.38, plus `n_folds > n_obs` on BOTH endpoints, `n_folds < 2` and
>   `n_rep < 1`, and a live `/healthz` after each rejection.
>
>   *Three code blocks that do not compile as printed.*  Every fenced
>   `moonbit` block in this README is a FRAGMENT -- `let data =
>   @moonbit_doubleML.DoubleMLData::new(x, y, d)` -- and MoonBit rejects a
>   module-scope `let` bound to a call ("Cannot infer the type of variable
>   data", Error 4074).  Measured: at module scope the fragment is
>   REJECTED; inside a function body the same fragment compiles.  So the
>   snippets were right and their PLACEMENT was not said out loud, and a
>   reader who pasted the Quick Start at the top of a file got a type error
>   that looked like a library bug.  Each block now carries a one-line
>   marker saying it belongs inside a function.
>
>   *Two published counts moved.*  `_verify/_verify_readme_snippets_1650.py`
>   published **7** and makes **10**: it now compiles each block TWICE --
>   once inside a function body, once at module scope -- and REQUIRES the
>   marker on any block that does not compile at module scope, so the promise
>   has an owner and the owner is the compiler.  Its count was also
>   ENVIRONMENT-DEPENDENT: 7 with the toolchain on PATH and 5 without it,
>   because one skip stood for three per-block compiles; there is now one
>   skip per compile per block, so the count is a property of the file.
>   `_verify/_verify_measurements_1650.py` published **70** and makes **79**:
>   it now owns the two n = 500 gaps BY TIER and the 16-cell swap's counts,
>   which its own I3 cannot see -- the gaps sit in the DON'T list, which is
>   ONE paragraph, so a marker that finds the LPLR item also finds the RDD
>   item (witnessed by a different gate), and the swap's counts are integers,
>   which are counts and stay out of the figure set.
>
>   *A finding that was wrong TWICE.*  Two fresh-eyes audits reported that
>   `doc/006_python_check` mis-split the Python cross-check coverage -- that
>   `DoubleMLQTE` is gated by both families, and that the guide's **16** /
>   **3** / **3** split is wrong.  BOTH were wrong, and the same mutation
>   settled it again: `DoubleMLQTE::fit` was broken, and the validate
>   family stayed GREEN while the pyexample family went RED.  The validate
>   script prints "quantile / LPQ / QTE parity: PASS", but its QTE row is a
>   DERIVED IDENTITY (`qte == pq - med_c`), not the estimator -- so its
>   LABEL overstates what it gates, and the guide's arithmetic is correct.
>   A script's printed label is not evidence of what it gates.
>
>   *Three numbers a reader could not check.*  "At `n = 500` the port and
>   upstream agree to ~0.007" named only the smaller of the two gated gaps
>   -- `0.007307` on the `nuisance_space` tier and `0.010609` on the
>   `instrument` tier -- and both are now named.  "all 8 of 8 swap cells"
>   is the port-`beta` half of a SIXTEEN-cell swap, and now says so.  And
>   the example table's "4 cohorts x 4 periods" is the DGP, while the
>   example prints `n_groups = 3`, because cohort 0 is never treated; the
>   row now says both.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round45_1650.py` breaks ONE promise -- a code block's
>   marker, the n = 500 gaps, the swap's total, the example table's
>   treatment-group count -- and the failure count must GROW at every step.
>   The run ends at **8** failures.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 46.**  The names that were not files.
>
>   A fresh-eyes audit read every promise the README makes and checked it
>   against the tree.  One was broken; three were imprecise.
>
>   *Seven script names that are not files.*  The upstream-owned paragraph
>   named the two scripts that GATE the port against upstream with their full
>   filename, and then named the seven that import the wheel for CONTEXT with
>   the bare stem -- `validate_apos`, `validate_cluster_iv`,
>   `validate_cluster_plr`, `validate_iivm`, `validate_irm`, `validate_pliv`,
>   `validate_plpr` -- while the files on disk are
>   `validate_apos_with_python.py` and so on.  All seven bare names were
>   verified ABSENT from the tree; all seven suffixed forms are PRESENT and
>   tracked.  A reader who copied the name got "No such file or directory",
>   and the same sentence, two lines earlier, wrote the full name.
>
>   *The backend command.*  The opening summary and the Features list said
>   the four backends were green "under `moon test --deny-warn`".  A bare
>   `moon test` runs the suite on ONE backend -- the document says so itself,
>   95 lines later in the Quick Start, where it explains that on this
>   toolchain a bare `moon test` reports `Total tests: 0` for `wasm` and
>   `native` and never reports `js`.  The three places that make the
>   four-backend claim now spell the per-backend command out.
>
>   *The census phrase.*  "22 estimators (`DoubleML*` structs)" is true of the
>   estimators and loose as a phrase: a reader who greps `struct DoubleML`
>   finds **34** structs in **20** files -- the 22 estimators plus 12 `*Data`
>   types -- and concludes the document is wrong.  Measured: 22 estimator
>   structs, in 19 production files, 16 holding one and 3 holding two.  The
>   sentence now uses the precise spelling the Status table already used.
>
>   *The registry that owns the claim.*
>   `_verify/_verify_count_referents_1650.py` keys on the PHRASE, so a
>   re-worded count is a new phrase -- and a phrase the registry does not
>   know is a claim nobody re-derives.  Its key was REPLACED, not kept: a
>   registered key that is absent from the README is itself a failing claim.
>
>   *The dry-run that has to keep biting.*
>   `_verify/_dryrun_round38_1650.py` mutates the census phrase to prove the
>   count is owned.  A driver that patches a phrase the document no longer
>   carries writes nothing and silently stops proving anything, so it now
>   mutates the phrase the reader NOW sees.
>
>   *A tree under test that was two releases at once.*  The round-44 driver
>   checks out HEAD and copies in the files it exercises, so the tree it
>   breaks carried this round's CHECKS and the last round's DOCUMENTS -- and
>   the baseline went red for a reason that had nothing to do with the
>   promise being broken.  Round 24's driver copies the documents its checks
>   read, and round 35 says why: "the CHANGELOG that publishes the failure
>   count has to be IN the tree under test, or the published-count check is
>   vacuous".  The round-44 and round-45 drivers now do the same.
>
>   *A second audit, and what it found.*  A fresh-eyes audit measured every
>   number in the published README against the tree and mutation-tested the
>   checks that guard them: **92** quantitative claims, **0** false, **3**
>   misleading -- and the three misleading ones are the four-backend command
>   and the census phrase, fixed above.  No number in the document is wrong.
>
>   *Three numbers that were true, and unwatched.*  The same audit found
>   numbers that are true today but that nothing in the tree would catch if
>   they rotted, because the check beside them derives a DIFFERENT figure and
>   the two were never tied together.  The Status table's own "**22**" and its
>   own "**220** / **65** / **129** / **26**" were two of them: the census
>   verifier derived 22 and 220 from the source and compared them with the
>   body sentence, and nobody compared them with the table's row.  The
>   "16 are CLI-style numeric demos" was the third -- a floating number, and
>   changing it to 15 left every check green.  All three are derived now, and
>   each was proven to bite by mutating the README and watching the check go
>   red.
>
>   *Still unwatched, and named here so they are not forgotten.*  The audit
>   found seven more: the sandwich-variance split, the 9 / 2 / 7 split of the
>   Python cross-checks, the bit-exact item and RNG-key counts, the
>   `examples/main` run census, the transcendental bit-pattern counts -- which
>   no probe derives, because the fixture deliberately emits no transcendental
>   -- and the pyroduct figures, which belong to a consumer repository that is
>   not in this tree.  They are true as measured; they are the next round's
>   work.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round46_1650.py` breaks ONE promise -- the seven script
>   names, the Status table's estimator count, its .mbt census, the CLI-style
>   demo count -- and the failure count must GROW at every step.  The run ends
>   at **4** failures.
>
>   *Checked and left alone.*  The README attributes the upstream score
>   vocabulary to `doubleml-for-py` **0.11.4** while the provenance labels are
>   measured against the installed **0.11.3**.  The 0.11.4 wheel was fetched
>   from PyPI and carries exactly the same 15 spellings and the same 21
>   estimator classes, so the attribution is right; the installed wheel is the
>   provenance anchor, and the string is pinned by a dry-run that fails if it
>   moves.
>
>   *The ledger is unchanged.*  This round publishes no new count, so
>   `_verify/_verify_ledger_counts_1650.py` (**44** checks) stays.
>
> * **Round 47.**  Four of the seven, and three that never were unwatched.
>
>   The round-46 entry above named seven numbers as "still unwatched".  This
>   round checked that list against the tree, and the list was wrong three
>   times out of seven.
>
>   *Three of them were already watched.*  The sandwich-variance split is
>   derived by `_verify/_verify_sandwich_coverage_1680.py`, which reads the
>   estimator set out of the source and ties the Status table's own
>   "**15 / 22**", "**4**", "**3**" and "**19 / 22**" to it.  The 9 / 2 / 7
>   split is derived by `_verify/_verify_tutorial_claims_1650.py`, and the
>   `examples/main` census by `_verify/_verify_layout_1680.py`: 18 banners,
>   12 distinct estimators.  The round-46 entry listed all three as
>   unwatched.
>
>   *The four that were unwatched, and what now watches them.*
>
>   *The bit-exact scope.*  "25 of the 25 bit-exact items" and "the 6 / 6 RNG
>   keys" were PRESENT-CHECKED: the strings were in the document, which says
>   nothing about whether they are true.  The new check
>   `_verify/_verify_bitexact_scope_1650.py` (**40** checks) derives the item
>   count from the validator's own `reference()` -- the number of `out[...]`
>   assignments IS the number of items it compares -- and the key count from
>   the fixture's seed list, and then RUNS the validator and compares the run
>   with both.  A document that says 26, a validator that drops an item and a
>   fixture that emits 5 seeds are three different failures, and the check
>   catches all three.
>
>   *The transcendental bit patterns.*  `sqrt 6/6`, `cos 6/6`, `sin 6/6` and
>   `ln 5/6` lived in two docstrings and nowhere else, because
>   `examples/bitexact` deliberately emits NO transcendental -- it must not:
>   `ln` differs from CPython by one ULP, and a fixture that emitted one
>   could not be a gate that passes.  So the probe is separate: a throwaway
>   program that prints the four functions of six arguments, so their
>   IEEE-754 bit patterns can be compared with CPython's.  The check measures
>   them and ties the README's table rows, the validator's docstring and the
>   fixture's docstring to the same measurement.  The invariants are the
>   STANDARD's, not the toolchain's: `sqrt` must agree everywhere, because
>   IEEE-754 requires it, and `ln` must disagree somewhere, because libm is
>   not correctly rounded.
>
>   *The two numbers the upstream paragraph published.*  The paragraph says
>   "**9** of its 24 scripts import the upstream `doubleml` wheel, and **2**
>   of those gate the port against upstream ... The other **7** import the
>   wheel for context".  The 9 and the 24 were derived; the 2 and the 7 were
>   not tied to anything -- the paragraph could have said "**3** of those
>   gate" and every check would still have been green.  The gating SET is now
>   derived: the upstream NAMES come from the AST (a name bound from a call
>   into the wheel), and a wheel importer gates iff some line outside a print
>   call mentions one of them together with a port token.  The old rule was a
>   line PATTERN, and it missed the shape `validate_lplr` uses, where the
>   comparison is on the line AFTER the difference.  The derivation finds
>   exactly `validate_did_cs_binary_with_python.py` and
>   `validate_lplr_with_python.py`, and the README's own **2** and **7** are
>   tied to it.
>
>   *The examples/main row's NAMES.*  The row said "`DoubleMLPLR` + 11 others
>   (IRM / PLIV / IIVM / ...)" and its COUNT was checked; its NAMES were not.
>   The row could have dropped RDD and named PLQ instead, and every check
>   would have stayed green.  The names are now read out of the row and
>   compared with the set the driver actually runs.
>
>   *The pyroduct figures, and what cannot be derived.*  The "Used By"
>   section quotes a downstream consumer's own numbers.  They are true, and
>   they are not derivable from here: the code that produces them is in
>   another repository, the published pyroduct package ships no sources, and
>   its published README does not carry the figures.  So the section now says
>   whose measurement they are and that this repository does not re-measure
>   them, and the check that owns it --
>   `_verify/_verify_package_claims_1650.py` (**53** checks) -- says so too.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round47_1650.py` breaks ONE promise -- the bit-exact item
>   count, the RNG key count, the `ln` row's count, the upstream paragraph's
>   two numbers, the examples/main row's NAMES, the pyroduct attribution --
>   and the failure count must GROW at every step.  The run ends at
>   **11** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**46** checks) is the new number.
>
> * **Round 48.**  The shape filter, and three sentences that claimed more
>   than the tree supports.
>
>   The user named `bobzhang/toml@0.4.3` -- 841 lines / 24 504 chars -- as
>   the shape to work from: a package README that states the CURRENT truth
>   and the boundaries, and carries no release-by-release archaeology, no
>   duplicated restatements and no internal call-site census.  Twelve
>   passages of that kind came out of this README.  Nothing MEASURED went
>   with them: every figure a verifier pins is still published, and the
>   checks that pinned one were RE-TARGETED rather than deleted -- a check
>   that followed a sentence must follow the FACT, not the wording.
>
>   *Three prose claims that were watched, and still wrong.*  A fresh-eyes
>   prose audit read the sentences and asked one question of each: does it
>   claim more than the tree supports?  Three did, and all three were
>   WATCHED claims -- the numbers in them were right, the SCOPE around them
>   was not.  A verifier that pins a string says the string SURVIVES; it
>   does not say the string is true.
>
>   *The Attribution promised a comparison that does not exist.*  "all three
>   ship upstream, and are compared against it" -- but
>   `validate_plpr_with_python.py` compares UPSTREAM's theta against the
>   HAND-ROLLED one and never against the port's, on a different dataset
>   (numpy's `default_rng` against the port's `chacha8_rng`), and
>   `pyexample_suite.py` contains no `plpr` at all.  PLPR has no upstream
>   gate; `DoubleMLLPLR` and `DoubleMLDIDCSBinary` have one.
>
>   *The small-n caution said both sides fail.*  "Both this port and
>   upstream fail there, in opposite directions" is false on the gate's own
>   output: the direction REVERSES with n (at n = 60 the port is well-behaved
>   and upstream is not; at n = 100 it is exactly reversed; at n = 160
>   neither fails).  The upstream half of the claim survives -- upstream
>   really is ill-posed there.
>
>   *The upstream gates do not all run upstream's own code.*  Eight of the
>   nine `pyexample_*` scripts import the `doubleml` wheel; `pyexample_rdd.py`
>   imports `rdrobust`, a different package.  The paragraph now names both.
>
>   *The new check.*  `_verify/_verify_prose_scope_1650.py` (**42** checks)
>   derives the upstream-gated estimator SET from the scripts themselves, the
>   small-n DIRECTION from the gate's own three measured rows, and the
>   reference package of each gate from the scripts' imports -- and ties the
>   README's three sentences to all three.  A sentence can be fixed by
>   another sentence; a sentence tied to a MEASUREMENT cannot.
>
>   *A dry-run that could only be run ONCE.*  Three of the tracked drivers
>   -- `_dryrun_round35`, `_dryrun_round46` and `_dryrun_round47` -- aborted
>   with "nothing to commit" when the sweep ran AFTER the release commit:
>   their copy-in was already in the clone, because the clone is cut at HEAD
>   and the commit carries it.  Eleven of the drivers already tolerated that;
>   these three did not, and this round's fourth inherited the gap by copying
>   one of them.  A check that can only be run once cannot be re-checked.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round48_1650.py` breaks ONE promise -- the Attribution's
>   comparison claim, the small-n caution, the upstream-gate reference, the
>   migration paragraph's set, the estimator table -- and the failure count
>   must GROW at every step.  The run ends at **20** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**48** checks) is the new number.
>
> * **Round 49.**  The nine sentences the README's neighbours were still
>   getting wrong -- and three more found while fixing them.
>
>   Round 48 shipped the README.  A fresh-eyes audit then read the SIX
>   TUTORIALS, the skill and the example README -- the documents the README
>   points its readers at -- and asked the same question of every sentence:
>   does it claim more than the tree supports?  Nine did, and the two worst
>   were real API-surface defects that no CI gate can catch, because one
>   lived inside a `moonbit nocheck` fence and the other was prose about the
>   dependency rule.
>
>   *"Every estimator follows" the constructor snippet.*  Six of the 22 do
>   not accept those arguments: `DoubleMLPQ`, `DoubleMLQTE` and
>   `DoubleMLLPQ` have no `n_rep`, and `DoubleMLBLP`, `DoubleMLPolicyTree`
>   and `DoubleMLRDD` take no `n_folds`, no `n_rep` and no `seed`.  The
>   sentence said "Every", and the sentence about `score` said it was "the
>   one that does not follow" -- so the document had one exception where it
>   had seven.
>
>   *The dependency rule was broken by the package it is about.*  The skill
>   allowed only `moonbitlang/*` and `riantr/*`, and the library's OWN
>   `moon.mod` declares `moonbit-community/sqlite3@0.2.3`, which is
>   neither.  No `.mbt` in the library imports it -- 0 references -- so it is
>   a dead entry, and the rule now says so instead of pretending otherwise.
>
>   *Upstream's factories were in the wrong place.*  Only 3 of the 18 live
>   under `doubleml/did/datasets/`; the other 15 are spread over three more
>   packages, only 8 of the 18 upstream names end in `_data`, and SIX are
>   renamed here -- including `make_pliv_data`, which upstream keeps
>   PRIVATE as `_make_pliv_data` and this port publishes.
>
>   *Three provenance headers named upstream factories that do not exist.*
>   `make_dgp_irm_data_discrete_treatments`, `make_pliv_data` and
>   `simple_rdd_dgp` -- none of them is an upstream name.  The port's own
>   record of upstream was wrong in three places, and doc/005 was right only
>   because it had been written from the upstream package rather than from
>   the headers.
>
>   *The rest.*  doc/006_python_check's transcript was not a prefix of what the loop
>   prints (it dropped the glob's SECOND file with no elision marker, and
>   put the verdict on the banner's line); the same document handed the
>   reader the loop CI's own comment identifies as the defect it was
>   rewritten to remove; doc/002 listed `scipy` as a direct dependency and
>   `rdrobust` with no constraint, while CI installs it pinned `>=2,<3` ON
>   PURPOSE; doc/004 put `DoubleMLQTE` with the scalar-quantile estimators
>   when it takes `quantiles`, an `Array[Double]`; "35 files in all" counted
>   a file its own description excluded; and doc/003 called a cross-section
>   a panel.
>
>   *The new check.*  `_verify/_verify_doc_scope_1650.py` (**133** checks)
>   ties each of the nine to a MEASUREMENT rather than to a string: the
>   constructor census is brace-matched out of the library's sources, the
>   dependency exception is parsed out of every tracked `moon.mod` (with the
>   COMMENTS stripped first -- a commented-out `import { ... }` in the
>   header of `moon.mod` is the easiest way to parse the wrong block), the
>   upstream census comes from a TRACKED manifest, and the transcript is
>   rebuilt from the glob order and each script's own trailing statement.
>
>   *The upstream manifest.*  Upstream publishes a WHEEL, and its 0.11.4
>   sdist is a local cache that is not tracked -- so a contract run in a
>   fresh clone cannot see it.  `_verify/_dgp_upstream_manifest_1690.txt`
>   is the tracked snapshot, carrying the sdist's sha256, and the port's
>   provenance headers must agree with it.  That agreement is the check that
>   found the three bad headers.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round49_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 5 -> 10 -> 17 -> 21 -> 24 -> 26 ->
>   28 -> 30 -> 33.  The run ends at **38** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**50** checks) is the new number.
>
> * **Round 50.**  Seven citations of upstream that named things upstream does
>   not have.
>
>   The README's own provenance table was already right.  The drift was in the
>   place the port records upstream FOR ITSELF -- the comments, the
>   provenance headers, the ledger.  Every `doubleml.*` path in those is a
>   claim that the path resolves, so all of them were resolved against
>   upstream 0.11.4 by the real import mechanics, not by matching file
>   names.  Seven did not resolve.
>
>   *Three were names upstream does not have.*  `LPQScore` (upstream's LPQ
>   class is `DoubleMLLPQ`), `DoubleMLRDD` (upstream's RDD class is `RDFlex`
>   -- `DoubleMLRDD` is THIS repository's name for its own estimator, which
>   is what made the wrong citation read as right), and
>   `_compute_sensitivity_elements` (there is no such function; the
>   base-class hook is
>   `doubleml.double_ml.DoubleML._sensitivity_element_est`).
>
>   *Two were shadowed by a re-export.*  A package's namespace is what its
>   `__init__.py` binds, and `from .mod import name` binds `name` there and
>   SHADOWS the submodule of the same name.  So
>   `doubleml.utils.gain_statistics` IS the function, and the citation that
>   appended `.gain_statistics` to it asked a function for an attribute it
>   does not have; the same held for `doubleml.plm.datasets._make_pliv_data`.
>
>   *Two were simply the wrong path.*  `DoubleML` is not exported at the
>   package's top level -- the class lives in `doubleml/double_ml.py` -- and
>   `_aggregate_coefs_and_ses` is in `doubleml/utils/_estimation.py`, not
>   `doubleml/utils/`.
>
>   *Two of the seven were claims about upstream that were wrong in
>   substance, not just in spelling.*  The RDD comment said that dropping
>   the kernel weights for a non-OLS learner "is the upstream convention":
>   upstream's `RDFlex` REQUIRES a learner that supports `sample_weights` and
>   always applies the kernel weights, so that is this port's own
>   restriction.  And the LPQ comment said upstream's `comp_prob` is
>   `E[D | Z=1] - E[D | Z=0]`: upstream estimates that difference doubly
>   robustly from the cross-fitted nuisance predictions.  The part the
>   port's own fix rests on -- that upstream computes it ONCE, on the full
>   sample -- was true, and is now said accurately.
>
>   *The CHANGELOG held five more broken citations*: three copies of the
>   claims above, in the v0.62.0, v0.23.0 and v0.19.0 entries, and two in the
>   v0.49.0 entry, where `DoubleMLDIDCSBinary` was named at the package's top
>   level rather than in `doubleml/did/`.  They are corrected in place, the way
>   the ledger's own history records: the round-33 entry corrected an earlier
>   published count for the same reason.
>
>   *The new check.*  `_verify/_verify_upstream_refs_1650.py` (**36** checks)
>   ties every citation to the TRACKED manifest of what resolves, and -- when
>   the upstream sdist is present -- to the artefact itself: the file is
>   there, and the name is on the recorded line.  The sdist is a local cache
>   and is not tracked, so in a FRESH CLONE that part is a SKIP, not a
>   failure.
>
>   *The upstream manifest.*  `_verify/_symbol_upstream_manifest_1690.txt`
>   records every cited path with the upstream file and line where the name
>   is bound or defined, and carries the sdist's sha256.  Two independent
>   derivations agree on all of them: the sdist model and a real import.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round50_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 2 -> 4 -> 5 -> 6 -> 7 -> 8.  The run
>   ends at **9** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**52** checks) is the new number.
>
> * **Round 51.**  A published count that two documents disagreed about.
>
>   The `ml_m` slot -- the propensity nuisance learner -- is the one constructor
>   argument whose default CHANGED the estimators' answers.  Seven of the
>   estimators that carry it now default to a classifier and eight to a
>   regressor.  The README said seven and named all seven.  `TUNE_DESIGN.md`
>   said SIX -- twice -- and this CHANGELOG had already corrected a "6 / 6"
>   claim to "**7 logistic / 8 linear**" in an earlier round.  Nothing watched
>   that document's number, so the two disagreed silently: a root-level design
>   record that no verifier audits, carrying a count the README contradicted.
>
>   *The count was never derived from the package.*  It was carried by hand
>   from one document to the next, and the only copy of it that no check owned
>   was the one in the document nobody audited.  So the new check reads the
>   split out of the SOURCE -- `LearnerDispatch::is_classifier` is the
>   package's own decision procedure, and the `ml_m` defaults are read from the
>   `DoubleMLXxx::new` signatures -- and holds every LIVE document that states
>   it against that derivation.  The CHANGELOG and the ENGINEERING body are
>   historical and are left alone: they record what was true when they were
>   written.
>
>   *The new check.*  `_verify/_verify_mlm_defaults_1650.py` (**20** checks)
>   measures the split and audits the documents that publish it.  No number is
>   hard-coded in it: the set may legitimately grow, and a migration that
>   changes the source without changing the documents is exactly what it is
>   for.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round51_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 4 -> 5 -> 6 -> 7 -> 10 -> 13 -> 14.
>   The run ends at **14** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**54** checks) is the new number.
>
> * **Round 52.**  Ten reproduction commands that named scripts nobody could
>   run.
>
>   A path in prose is a promise: it must exist, and it must be TRACKED.  Ten
>   `python <script>.py` commands in tracked Markdown named scripts that are
>   not in the repository -- and not one of the nine was EVER committed, because
>   no commit in this repository's history adds a file by any of those names,
>   so a reader could never have run one of them.  Every one of them sat in a
>   document that no verifier opened.
>
>   Three of those documents did not merely go stale; they contradicted the
>   CHANGELOG.  `CLUSTER_UPSTREAM_PARITY_1680.md` carries a section that says
>   the dead commands "pointed at nothing", that "a reproduction command that
>   cannot be run is worse than none, because it reads as evidence", and that
>   they were "Replaced with the two scripts that do exist" -- and then lists
>   three, and leaves the original block untouched.  So the CHANGELOG
>   published "the block now cites the three scripts that do" while the block
>   cited none of them.
>
>   `PQ_QTE_GATE_DESIGN_1680.md` still said "gate not yet built" after
>   `pyexample_pq.py` had landed, and `RDD_PARITY_1680.md` said of a docstring
>   "Not yet corrected ... Logged, not fixed" -- in the SAME commit that
>   corrected it, whose own message says "Also corrects a docstring stating
>   an identity its own test cannot see".  That note also quoted a test name
>   that does not exist: the test is
>   `v116_tau_bc_equals_the_collapsed_form_only_when_b_equals_h`, and the
>   note said `..._when_b_equals_h`.
>
>   *The new check.*  `_verify/_verify_repro_paths_1650.py` (**28** checks)
>   holds every live document's reproduction commands, status lines and counts
>   against the tree, and reads the root `README.md` symlink from the INDEX
>   rather than from the working tree -- this host materialises it as a
>   hardlink and a fresh clone writes a 13-byte stub, so a check that read
>   the file would publish a count that differs between clones.  A document
>   may keep its original text; it says so in its own words, and the check
>   says so in its detail line rather than passing silently.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round52_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 8 -> 9.
>   The run ends at **9** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**56** checks) is the new number.
>
> * **Round 53.**  Paths named in prose, and the promise they make.
>
>   Round 52 held that a *reproduction command* is a promise.  This round holds
>   that a path named in PROSE is the same kind of promise: a document that
>   says its evidence was captured under a named file tells the reader that
>   the file exists and is worth opening.  A census of every tracked Markdown
>   document found **34** such promises in LIVE documents that no reader could
>   keep -- seven named scripts that were NEVER committed, four named files
>   that were tracked until 0.12.0's scratch-hygiene release untracked them,
>   nine named a script that had been RENAMED (to
>   `validate_with_python.py.archived_2026_09_25`, the name it has today), and
>   two named a CI workflow that had been RENAMED to
>   `.github/workflows/check.yml`.
>
>   *The new check.*  `_verify/_verify_path_promises_1650.py` (**296** checks) holds every path named in prose in every live document against the
>   tree, and reads the root `README.md` symlink from the INDEX rather than
>   from the working tree -- this host materialises it as a hardlink and a
>   fresh clone writes a 13-byte stub, so a check that read the file would
>   publish a count that differs between clones.  A document may keep its
>   original text; it says so in its own words, and the check says so in its
>   detail line rather than passing silently.
>
>   *A check that grew.*  `_verify/_verify_repro_paths_1650.py` published
>   **28** and makes **30**: the repair record this round tracks carries two
>   more reproduction commands, and a command is a check.
>
>   *A rule the two verifiers share.*  A path that is POSSESSIVELY
>   attributed to another repository is a reference to that repository's
>   file, not a promise about a file here.  The skill-claims verifier
>   already drew that line -- the skill names one of another package's own
>   files, and that file is supposed to be ABSENT from this tree -- and
>   this check draws it too, because two verifiers that disagree about the
>   same file are worse than one that is wrong.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round53_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8.
>   The run ends at **8** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**58** checks) is the new number.
>
> * **Round 54.**  Numbers in prose are promises too -- and nothing held them.
>
>   Round 53 held that a path named in prose is a promise.  This round holds
>   that a NUMBER in prose is the same kind of promise.  The documents that
>   describe the tree as it stands -- `README.mbt.md` and
>   `skills/moonbit_doubleML.md` -- state dozens of counts: 22 estimators in 19
>   source files, 220 `.mbt` files, 24 Python validators, 21 example binaries,
>   15 of 22 estimators with a scalar sandwich SE, 11 `LearnerDispatch`
>   variants, 26 whitebox files holding 169 test cases, 7 of 22 estimators
>   taking a `score` argument.
>
>   Every one of them was MEASURED true -- and none of them was held by
>   anything.  The next `.mbt` file would have falsified "220" silently, and
>   the README would have gone on claiming it.  A number nobody checks is a
>   number that is already on its way to being wrong.
>
>   *The new check.*  `_verify/_verify_number_promises_1650.py` (**51** checks)
>   measures each quantity from the tree and checks EVERY place the two
>   documents state it -- a number that appears in six sentences is six
>   promises, not one.  The claim is PARSED out of the document, never
>   hand-copied: a check that compares the tree against a number typed into
>   the verifier is not a check of the document at all.
>
>   *Counts are not enough.*  One mechanism swaps an estimator name in the
>   sandwich-variance row and leaves the count alone.  A check that compares
>   only counts cannot see it, so the contract checks the NAMES too.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **296** and makes **298**: this round's banner names two more paths, and a
>   path named in prose is a check.
>
>   *A hole the dry-run found.*  The first draft of the check matched
>   "**22** estimators" and not "**22 estimators**" -- the bold around the
>   whole phrase rather than around the number -- so the README's most
>   prominent estimator claims were invisible to it.  The dry-run caught it:
>   the mechanism that changed the number did not move the failure count, and
>   a mechanism that moves nothing is not being measured.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round54_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10.
>   The run ends at **10** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**60** checks) is the new number.
>
> * **Round 55.**  A citation names a PLACE -- and the place has to be inside
>   the file.
>
>   Round 53 held that a path named in prose is a promise.  Round 54 held that a
>   number in prose is a promise.  This round holds that a CITATION -- a path
>   with a LINE RANGE, `ssm.mbt:73-74` -- is the same kind of promise with a
>   third half: the place it names must be INSIDE the file.
>
>   The scanner could not see that form at all.  Its path token accepts no
>   colon, so a citation was not a path to it -- and the live documents hold
>   **474** citations, every one of them invisible.  A citation is what a
>   reader follows, and nothing was watching where it pointed.
>
>   **Not retained in this repository**: `cmd/`, `_build/`,
>   `__generated_driver_for_blackbox_test.mbt` -- the paths this entry names
>   are the ones the documents describe and this repository does not keep.
>
>   *The scope device, widened by two DERIVED signals.*  Round 53 scoped a
>   promise by "a directory the repository has NOW".  Two places this
>   repository wrote to fell outside that: `cmd/`, the package's entry-point
>   tree -- a deleted tracked path says the directory was here once -- and
>   `_build/`, which the repository's own `.gitignore` names, so the toolchain
>   writes HERE.  Neither signal is a list this project keeps: one comes out of
>   the git history, one out of the tracked `.gitignore`.
>
>   *What it measured.*  **31** promises in **18** live documents that no reader
>   could keep: twenty-seven paths under the `cmd/` tree, and four citations --
>   `cmd/main/main.mbt`, `cmd/apos/main.mbt`,
>   `_build/_verify_TODO3_snapshot.mbt`, and the `moon test` driver
>   `__generated_driver_for_blackbox_test.mbt`.
>
>   *The third way to discharge a promise, in a form a scanner can read.*
>   Round 53's rule: point at the file that exists; TRACK the file; or say in
>   the house's own words that it is not there.  The third way now has a form:
>   a line that opens with the words **Not retained in this repository**, and
>   then names the paths the document does not keep.  The words are the
>   DOCUMENT'S, never a list this project keeps.  Eighteen documents say it
>   once, in their own words, and every mention of the path in that document
>   is discharged by it.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **298** and makes **443**: a citation is a check, and so is every distinct
>   path it names.
>
>   *A driver that grew with it.*  `_verify/_dryrun_round53_1650.py` now ends
>   at **9** failures: its "a historical document is live again" mechanism
>   trips one more check, because `cmd/main/main.mbt` is a promise now that
>   `cmd/` is in scope.  A published count is a promise too, and the round
>   that makes it false republishes it -- which is what this entry is.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round55_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 1 -> 2 -> 3 -> 4 -> 6 -> 9 -> 10 -> 11.
>   The run ends at **11** failures.
>
>   *The ledger does not move.*  This round publishes no count for a NEW
>   check, so `_verify/_verify_ledger_counts_1650.py` (**60** checks) is still
>   the number.
>
> * **Round 56.**  The tutorial pages' numbers -- and the probe that found
>   nobody was holding them.
>
>   Round 53 held that a path named in prose is a promise.  Round 54 held that
>   a number in prose is a promise.  This round holds that the TUTORIAL pages
>   under `doc/` -- and the api_server README -- make numbers too, and that
>   their numbers had NO holder at all.
>
>   The instrument was a MUTATION PROBE.  It changed one number in one page,
>   ran every tracked verifier that reads that page, and asked which ones
>   failed.  **26** claims had no holder: nothing in this repository would
>   have failed if `doc/001_introduction` had said "17 regressors", or
>   `doc/004_estimators` "default `[0.7]`", or the api_server README "the
>   body cap is 32 MiB".
>
>   *The new check.*  `_verify/_verify_doc_numbers_1650.py` (**52** checks)
>   measures each quantity from the tree -- the estimator census, the
>   `LearnerDispatch` enum, the DGP factories and the accessors of the types
>   they RETURN, the Python script families, the constructor defaults, the
>   propensity-learner defaults, the CI workflow, the api_server's own source
>   -- and checks every place the pages state it.  The claim is PARSED out of
>   the document, never hand-copied, and a number that appears in two
>   sentences is two promises, not one.
>
>   *What it found.*  Nothing FALSE: every one of the **26** claims was true
>   of the tree when it was measured.  That is not a defence of them.  A
>   promise nobody watches rots in silence, and the next `.mbt` file would
>   have falsified "17 `dgp_*.mbt` modules" without a single red line.
>
>   *Two claims that were the SAME number in two sentences.*  The
>   `doc/006_python_check` page says "**9** of the 24 import the upstream
>   `doubleml` wheel" and, eight lines earlier, "upstream's wheel in **9**".
>   One was held and one was not: a quantity is a promise per SENTENCE, not
>   per quantity.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **443** and makes **446**: a path named in prose is a check, and this
>   round's banner names three more of them.
>
>   *A check that was measuring the wrong tree.*  The round-9 verifier's
>   version-literal scan WALKED THE FILESYSTEM.  A scratch clone of the tree
>   sitting at the repository root carries every version literal in it, so the
>   check reported a dozen version sites that no reader could open and no
>   bump script could reach.  The scan is now scoped to the TRACKED tree --
>   the repository, not the checkout -- which is what the check always meant.
>   `_verify/_verify_round9_docs_1644.py` (**65** checks) is the number it
>   makes now, in the house's own summary shape.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round56_1650.py` breaks ONE promise -- one number in one
>   page -- and the failure count must GROW at every step: 0 -> 1 -> 2 -> 3 ->
>   4 -> 5 -> 6 -> 7 -> 8 -> 9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 16 -> 17 ->
>   18 -> 19 -> 20 -> 21 -> 22 -> 23 -> 24 -> 25 -> 27 -> 28 -> 29.  The run
>   ends at **29** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**64** checks) is the new number.
>
> * **Round 57.**  AGENTS.md -- the document an agent opens first, and the
>   one nobody was holding.
>
>   Rounds 48-56 audited the README, the six tutorials, the skill and the
>   example README.  `AGENTS.md` is the only live document at the repository
>   ROOT that none of them touched -- and it is the FIRST thing an agent
>   opens.  A MUTATION PROBE on it -- change one claim, run every verifier
>   that reads the document, ask which ones fail -- says that THREE of the
>   eleven claims it probed were held by anybody and EIGHT were held by
>   NOBODY.  The library's location, the tutorial range, the dependency
>   rule, the async version, the commit citation, the public API calls and
>   the "no test file" claim could all have been wrong, and no red line
>   would have appeared.
>
>   *The probe had to be fixed twice before it measured anything true.*  The
>   first pass took the readers to be "the verifiers whose SOURCE names the
>   document" -- an UNDER-approximation: the path-promises verifier reads
>   every tracked markdown file, so it holds AGENTS.md's path promises
>   without the string "AGENTS.md" ever appearing in its source.  The reader
>   set is now MEASURED at runtime, with an audit hook that logs every file
>   a verifier opens: SEVEN verifiers open AGENTS.md.  The second pass wrote
>   the mutation into the clone's working tree, and the path-promises
>   verifier reads documents from the INDEX -- on purpose, so its check
>   count is the same in every clone -- so it could not see a mutation that
>   was never COMMITTED.  Each mutation is committed now, and the probe
>   says EIGHT were held by nobody before this round and NONE after it.
>
>   *Three claims were FALSE of the tree.*
>
>     * the DEPENDENCY RULE.  "Only official (`moonbitlang/*`) packages are
>       allowed.  Non-official packages may only be `riantr/*`" -- while the
>       library's own `moonbit_doubleML/moon.mod` declares
>       `moonbit-community/sqlite3@0.2.3`, which is neither.  Round 49 gave
>       `skills/moonbit_doubleML.md` exactly this correction, naming the one
>       declared line that does not meet the rule; AGENTS.md was never given
>       the same edit, so two documents described two different rules.
>     * the INTERFACE FILE.  "each package has a generated interface file
>       `.mbti`" -- the toolchain writes `pkg.generated.mbti`, the tracked
>       `.gitignore` ignores it, and NO tracked file ends in `.mbti` at all.
>       "Check the diffs of `.mbti` file" asked for a diff that `git diff`
>       can never produce.
>     * the PACKAGE LAYOUT.  "each directory contains a `moon.pkg` file" --
>       `doc/` is a MODULE of six packages and has no `moon.pkg` of its own,
>       and `_verify/` holds MoonBit source that belongs to no package.
>
>   *The new check.*  `_verify/_verify_agents_claims_1650.py` (**66** checks)
>   derives every claim from the tree -- the workspace census from
>   `moon.work`, the dependency carve-out from every tracked `moon.mod`'s
>   import block with the comments stripped, the package census from the
>   tracked tree, the interface file's name from the tracked `.gitignore`,
>   and the commit citation from the git object database -- and checks every
>   place AGENTS.md states it.
>
>   *A claim about the TREE is broken by changing the TREE.*  The last
>   mechanism of the dry-run commits a `deprecated.mbt` into the scratch
>   clone, because the verifier's scope is the TRACKED tree: a file that
>   exists only in a working copy is not a claim about the repository.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **446** and makes **450**: a path named in prose is a check, and this
>   round names four more of them.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round57_1650.py` breaks ONE promise, and the failure
>   count must GROW at every step: 0 -> 2 -> 4 -> 6 -> 7 -> 9 -> 10 -> 12 ->
>   16 -> 17 -> 19 -> 20 -> 21 -> 22 -> 23 -> 25 -> 26 -> 28 -> 29 -> 31 ->
>   32 -> 33 -> 35.  The run ends at **35** failures.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**66** checks) is the new number.

> * **Round 58.**  The SECONDARY documents -- the four that rounds 48-57 never
>   audited.
>
>   Rounds 48-57 audited the README, `AGENTS.md`, the six tutorials, the skill
>   and the example README.  Four LIVE documents were left: `.githooks/README.md`,
>   `doc/README.mbt.md`, `doc/menu.json` and
>   `_verify/upstream_prove_1649/README.md`.  The same MUTATION PROBE says they
>   were in the state `AGENTS.md` was in: of the **24** claims the BASELINE
>   probe could put to the test, **18** were held by NOBODY -- the hook's
>   command, the member count, the tutorial table, the tutorial target, the
>   menu, the toolchain the proof re-audit was measured on and the per-case
>   error counts could all have been wrong, and no red line would have
>   appeared.  After this round, **25** claims probed and **NONE** held by
>   nobody.
>
>   *The reader set is MEASURED at RUNTIME*, with an audit hook that logs
>   every file a verifier opens: **5** verifiers open `.githooks/README.md`,
>   **6** open `doc/README.mbt.md`, **1** opens `doc/menu.json` and **4** open
>   the proof re-audit README.  The six claims that DID have a holder were
>   held by `_verify/_verify_round11_handoffs_1646.py` (the hook's tracked
>   mode), `_verify/_verify_path_promises_1650.py` (two paths) and
>   `_verify/_verify_round14_upstream_1649.py` (the two per-case error counts)
>   -- and one of round 11's two did not hold a claim at all: it PINNED the
>   falsehood, so correcting the document would have failed the check.
>
>   *Eight claims were FALSE of the tree.*
>
>     * the TASK COUNT.  "measured: `moon: ran 54 tasks`" -- the number is not
>       holdable at all: it changes with the build state and with the toolchain,
>       and `moon check` prints "no work to do" instead of a count on a warm
>       tree.  It was REPLACED by the member count, which `moon.work` derives.
>     * "It is the same command `publish.yml` runs before it publishes."  It is
>       not: `publish.yml` runs `moon check --target "$target" --deny-warn`.
>     * "`moon check` does **not** check `_test.mbt` files -- only `moon test`
>       compiles them."  FALSE: `moon check`'s OWN PLAN type-checks the
>       `_test.mbt` files and the `readme.mbt.md` doctests.  `moon check`
>       type-checks them; only `moon test` RUNS them.
>     * "the QA LOOP -- those live in `.github/workflows/`".  The QA LOOP's own
>       scripts live in `.github/scripts/qa_loop/`.
>     * "See the README's 'What CI actually gates' table."  There is no such
>       table in the README -- it is a section of `ENGINEERING.md`.
>     * "the current toolchain" (six times) and "the current proof frontend":
>       a 2026-10-20 audit cannot describe the toolchain in use today.  The
>       document now says **the audited toolchain**, and names the versions it
>       was measured on.
>     * "the controls are classified `PLATFORM_ERROR` rather than `PROVED` in
>       `out/b0_control.log`".  The log holds the RAW EVIDENCE; the label is
>       `run_reaudit.py`'s.
>     * "The toolchain has moved five patch releases since."  Reworded so the
>       gap is between the versions the document itself names -- `v0.10.11` and
>       the audited `v0.10.16` -- which keeps it true forever.
>
>   *A check that HELD THE FALSEHOOD.*  `_verify/_verify_round11_handoffs_1646.py`
>   REQUIRED the sentence "does **not** check `_test.mbt` files" to be in the
>   hook README -- it asserted the error, not the truth.  It now requires the
>   corrected sentence, and its own count is unchanged at **45**.
>
>   *The new check.*  `_verify/_verify_secondary_docs_1650.py` (**151** checks)
>   derives every claim from the tree -- the member count from `moon.work`,
>   the hook's mode from `git ls-files -s`, the cross-check count from the
>   tracked `validate_*_with_python.py` glob, the doc-package census from the
>   tracked tree, the `_test.mbt` question from `moon check --dry-run`'s own
>   plan, the per-case error counts from the tracked `out/*.log` files, and the
>   patch-release gap from the two versions the document names.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round58_1650.py` breaks ONE promise, and the failure count
>   must GROW at every step.  The run ends at **28** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **450** and makes **459**: a path named in prose is a check, and this round
>   names nine more of them.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**68** checks) is the new number.

> * **Round 59.**  The README's SHAPE -- measured against the two references.
>
>   Rounds 48-58 audited the TEXT of every live document.  This round audited
>   the SHAPE: what a reader is GIVEN, and in what order.  The two reference
>   packages the user named -- `Ridge-Lab/capnp@0.1.0` and `gaato/discord@0.10.0`
>   -- were measured feature by feature against this README, and FOUR gaps came
>   out of the comparison.
>
>   *The README carried NO IMAGE at all.*  Both references open with a CI
>   badge; this one had none, and nothing would have said so, because the
>   README is GENERATED -- a generator change can lose a section without any
>   red line.  It now opens with a badge on `.github/workflows/check.yml`: the
>   workflow named "CI", which runs on every push to `main` and `master` and on
>   every pull request.
>
>   *The status was 590 lines down.*  discord opens its prose with a
>   one-paragraph STATUS; this README's status sat under "Development status",
>   past the Features list, the estimator table, the API reference, the
>   propensity section and the pitfalls.  There is now one under the opening
>   paragraph, and every element of it is DERIVED from `moonbit_doubleML/moon.mod`:
>   MIT is the manifest's `license`, the four backends are its
>   `supported_targets`, and the estimator count is measured.  NO version
>   literal goes in it: a version in a new place is a new bump site, and a
>   bump site the bump script does not know about is a stale number waiting to
>   happen.
>
>   *A shape element that was REFUSED.*  capnp states a MINIMUM toolchain --
>   the lowest MoonBit it supports.  Nothing in this tree establishes a floor:
>   `moonbit_doubleML/moon.mod` declares no toolchain constraint, and the
>   workflows install the LATEST `moon` rather than pinning one.  So no floor
>   is published.  What the README says instead -- the toolchain it was
>   VERIFIED on -- is what is held.
>
>   *The shape was not HELD.*  Nothing failed if the next bump dropped the
>   badge, because the README is GENERATED -- a generator change can lose a
>   section without a red line.  `_verify/_verify_readme_shape_1650.py`
>   (**29** checks) holds the shape now: the badge must name a
>   TRACKED workflow, point at
>   this project's own repository, carry that workflow's own name, and belong
>   to a workflow that runs on a push to the release branch; the opening must
>   keep the reference's ORDER -- title, badge, paragraph, status -- and the
>   status paragraph must name the manifest's licence, the manifest's backends
>   and the measured estimator count, must point at a section that exists,
>   must say what is not claimed, and must carry no version literal.  The
>   shape the references SHARE is held too: a console block with a command and
>   its output, the install command, `moon update`, a MoonBit import block, a
>   "not covered" section, a licence section, an attribution section, a table
>   row naming every declared backend, the toolchain statement and the
>   test-count row.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round59_1650.py` breaks ONE promise, and the failure count
>   must GROW at every step.  The run ends at **28** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **459** and makes **461**: a path named in prose is a check, and this
>   round names 2 more of them.
>
>   *The ledger moves.*  This round publishes a count for a new check, so
>   `_verify/_verify_ledger_counts_1650.py` (**70** checks) is the new number.

> * **Round 70.**  The dependency pin moved, and the TOOLCHAIN moved with it.
>
>   The tree's own dep-pin check turned RED: the registry published
>   `moonbitlang/async@0.22.6` and the pin was one version behind.  Nothing
>   was wrong with the DOCUMENTS -- the TREE was behind, and the check said so
>   before anything was published.
>
>   *The move was not a number edit.*  0.22.6 imports
>   `moonbitlang/core/async`, a subpackage that only the core shipped with
>   `moon 0.1.20261028` carries.  On `moon 0.1.20261023` the build plan could
>   not even be SOLVED -- "Cannot find import 'moonbitlang/core/async' in
>   moonbitlang/async@0.22.6" -- and the library stopped building altogether.
>   So the toolchain moved with the dependency, which is what the workflows
>   do anyway: they install the LATEST `moon`.
>
>   *Every claim that NAMED the toolchain was re-derived, not re-labelled.*
>   The four per-target counts are still **1117 / 1123 / 1117 / 1117**; a bare
>   `moon test` still reports `Total tests: 0` for `wasm` and `native` and
>   "no test entry found" for `js`; `@std/env`, `@std/fs`, `@std/io` and
>   `@std/process` still do not resolve; `read_file` is still error **4021**;
>   and `train` is still not reserved.  All five hold, so only the LABELS
>   moved -- in the README, in `AGENTS.md`, in the tutorials, in the skill, in
>   the bitexact harness, and in the two workflows that justify
>   `--allow-inert`.
>
>   *The pin is now DERIVED.*  The README named it in four places, and every
>   one of them was a literal in the builder -- so the class of staleness was
>   "the registry publishes a version and the document keeps naming the old
>   one".  The builder now reads the pin from `moonbit_doubleML/moon.mod` and
>   the quoted `dependencies` WARN from the harness's own rule, so the README
>   CANNOT name a pin the tree does not declare.
>
>   *The check that would have caught it.*  The dependency RULE's own example
>   named a pin, and NOTHING held it to the tree: the manifest could move and
>   the rule could keep quoting the old version, and no check would have said
>   so.  `_verify/_verify_dep_pins_1680.py` now asserts that a version a
>   document names must be a version the tree declares -- the class it was
>   already meant to own -- and the rule's example is in it.
>
>   *The recorded evidence was stale too.*  `_verify/_qa_fast_1639.json` was
>   added in v0.164.31 and had never been refreshed; its `dependencies`
>   evidence still named `0.22.5`, and the check that compares the README's
>   quote against it caught exactly that.  It is refreshed now, from a REAL
>   run of the harness on the new toolchain: the same tally (**19** PASS,
>   **10** SKIP, **2** WARN), and the artifact records the toolchain that
>   measured it.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round70_1650.py` breaks ONE promise -- the rule's
>   example, the table's row, the service sentence -- and the failure count
>   must GROW at every step.  The run ends at **4** failures.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **461** and makes **463**: a path named in prose is a check, and this
>   round names 2 more of them.
>
>   *The ledger holds.*  This round publishes no count for a NEW check -- it
>   extends one that already had one -- so
>   `_verify/_verify_ledger_counts_1650.py` (**70** checks) is unchanged.

> * **Round 71.**  The README states the FLOOR a reader must meet.
>
>   Round 59 REFUSED to publish a minimum toolchain, and the refusal was
>   right at the time: nothing in this tree established one.  The tree pinned
>   `moonbitlang/async@0.22.5`, whose published source does not touch the
>   core at all, so ANY `moon` could build this package.  Round 70 moved the
>   pin to `0.22.6` -- and THAT is what established the floor, because
>   0.22.6 is the first published version whose source imports a subpackage
>   the core has to provide.
>
>   *The floor is measured, not asserted.*  Every published version from
>   0.10.0 to 0.22.5 has ZERO files importing `moonbitlang/core/async`;
>   0.22.6 has six.  The core that ships with `moon 0.1.20261028` carries the
>   subpackage; the core of `moon 0.1.20261023` does not.  And a CONSUMER
>   proves it end to end: the published package builds on the new core, and
>   on the old one it fails to solve with "Cannot find import
>   `moonbitlang/core/async` in `moonbitlang/async@0.22.6`" -- the same
>   consumer, the same package, two cores, so the failure IS the floor.
>
>   *Dead is not the same as harmless.*  The "Not covered" section called
>   both declared dependencies dead, and a reader could reasonably take that
>   to mean they cost nothing.  One of them does: the dead pin is what sets
>   the floor.  The other one does not -- `sqlite3`'s published source
>   imports five core subpackages, and the older core carries every one of
>   them.
>
>   *The check that holds it.*  `_verify/_verify_toolchain_floor_1680.py`
>   runs **21** checks: the pin is read out of `moon.mod`, the published
>   source of that pin is read out of the toolchain's own downloaded copy,
>   the installed core is asked whether it carries the subpackage, and the
>   Installation section and the Status table are asked whether they name
>   the same toolchain.  A floor NEWER than the toolchain the release was
>   verified on would be a release that cannot build on the floor it
>   publishes -- and that is a check too.
>
>   *The dependency RULE is not the only place a version appears.*  The
>   Installation section names the pin the floor is built on, so
>   `_verify/_verify_dep_pins_1680.py` now holds that site as well: a
>   version a document names must be a version the tree declares.
>
>   *A dry-run of this round's own checks.*  Each mechanism in
>   `_verify/_dryrun_round71_1650.py` breaks ONE promise -- the pin, the
>   toolchain agreement, the floor's direction, the cost of the dead pin,
>   the installation guide, and the core the measurement reads.  The run
>   ends at **9** failures, and the capture is published.
>
>   *A check that grew.*  `_verify/_verify_path_promises_1650.py` published
>   **461** and makes **465**: a path named in prose is a check, and
>   this round names 2 more of them.
>
>   *The ledger moved.*  This round publishes a count for a NEW check, so
>   `_verify/_verify_ledger_counts_1650.py` (**72** checks) is the new number.
>
>
>
>
>
## The README as it stood at v0.164.11

A pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- 22 estimators in total. **19** match a
class of the same name in upstream; **2** are upstream estimators under
a different name -- `DoubleMLRDD` is upstream's RDD estimator (upstream
calls it `RDFlex`) and `DoubleMLDIDCrossSection` is upstream's
`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream
class** -- it is this port's variant of upstream's multi-period
`DoubleMLDIDMulti`, which upstream keeps in a single class that this
port splits in two. Those provenance labels are re-measured against the
**installed** `doubleml` 0.11.3 package, not asserted -- see the
estimator table below and `_verify/UPSTREAM_PROVENANCE.md`.
`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` were for
several releases described here as MoonBit-specific extras; all three
ship upstream and the table marks them *(upstream)*.

Targets library authors and tool developers who need causal inference,
panel data estimation, instrumental variable estimation, regression
discontinuity, policy evaluation, or interpretable machine learning
inside the MoonBit ecosystem. Delivers a unified
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` API across all
22 estimators, robust variance estimation, propensity-score
processing, multiple-testing correction, and a reproducible validation
pipeline (24 / 24 Python reference scripts PASS) -- on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`.

##Status

| Item | Value |
|------|-------|
| Repository | `https://github.com/riantr/moonbit_doubleML` |
| Author | `riantr` |
| License | MIT (port of upstream `doubleml-for-py`, BSD-3-Clause) |
| `moon.mod` version | **0.164.11** |
| Toolchain | `moon 0.1.20261016` -- the version every number in this table was measured on; a bare `moon` from `cli.moonbitlang.com` may be newer |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | **220** `.mbt` files (**65** production + **129** blackbox test + **26** whitebox test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **1117 / 1117 / 1117** |
| Tests (wasm-gc) | **1123 / 1123** (lib + 6 doc tutorials) |
| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`). Introduced v0.89.0 |
| Python cross-checks | **24 / 24 PASS** (`validate_*_with_python.py`); 25 of the 25 bit-exact items and 6 / 6 RNG keys are IEEE-754 identical to CPython |
| HTTP service | `examples/api_server/` -- hand-rolled on `moonbitlang/async`, no third-party framework |

##Features

**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`
estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
`DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,
`DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,
`DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,
`DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)
in 19 source files. **19** are marked *(upstream)* and mirror a
name-identical `doubleml-for-py` class; **2** are marked
*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and
`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and **1**,
`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)*.
The DID family is where the naming crosses, so it is worth spelling out.
Upstream's `DoubleMLDIDCS` is the *repeated cross-sections* estimator,
which is this port's `DoubleMLDIDCrossSection`. Upstream's
`DoubleMLDIDMulti` is the *multi-period* estimator, and upstream keeps
it in **one** class -- this port splits it in two: `DoubleMLDIDMulti`
is the 1:1 counterpart (it carries upstream's `gt_combinations`
selector and upstream's `standard` / `all` / `universal` keywords),
and `DoubleMLDIDCS` is the port's variant without the selector, which
derives its own `(g, t)` grid and transcribes upstream's `did_cs.py`
machinery. A 1:1 map cannot give one upstream class two counterparts,
so `DoubleMLDIDCS` is labelled for what it is rather than given a
partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- were previously marked *(extra)*,
which was wrong: all three ship upstream, so they had a reference
implementation all along.

**One API shape, with the differences named** -- every estimator is built
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
`depth` / `honest`, and each DID variant takes its own data type.

**Cross-fitting infrastructure** -- `kfold`, repeated cross-fitting,
stratified K-fold (`kfold_stratified`), `chacha8_rng`-based seeded
PRNG (`chacha8_rng(seed)`), and Kahan summation. Default `seed=3141`;
same seed yields byte-identical DGP outputs across runs.

**Vectorised cross-fit helpers (v0.81.0+)** -- `vectorized.mbt`
exposes `matrix_predict` (Kahan-compensated `X @ weights + bias`),
`vector_subtract`, `vector_add`, and `vector_scale` as public
free functions. `DoubleMLIRM::fit` / `fit_cluster` /
`sensitivity_analysis` and the matching `DoubleMLPLR` paths now
route the per-observation residual extraction through
`vector_subtract` instead of an inlined per-iteration load /
subtract. The helpers are pure element-wise loop wrappers
today -- the public API is fixed so a v0.82+ release can swap
the bodies to a SIMD-vectorised backend (or external call to
a BLAS-style library) without breaking callers.

**`ml_m` is a classifier where the propensity carries identification --
and that is NOT everywhere.** Upstream makes no OLS default: `ml_m` is a
required argument, validated as `regressor=False, classifier=True`
(`irm.py:157`) and read back with `predict_proba` (`irm.py:161`). Where
`m_hat` is first-order in the score, an OLS propensity is unbounded, enters
as `1 / m_hat`, and `propensity_clip` (default `1e-6`) merely caps that at
`1e6` -- so nothing raises, it just returns wrong numbers. Measured on a
fixture with true `ATE = 1.5`:

| `ml_m` | `coef` | `rv` |
|---|---|---|
| `linear_regression` | **-225.86** | 0.043 |
| `logistic_regression` | **1.44** | 0.842 |

The port used to default `ml_m` to `LearnerDispatch::linear_regression()`
everywhere. **`DoubleMLIRM` was migrated in v0.132.0**,
**`DoubleMLAPO` in v0.134.0**, **`DoubleMLAPOS` in v0.135.0**,
**`DoubleMLSSM` in v0.138.0**, **`DoubleMLPQ` / `DoubleMLQTE` in
v0.139.0** and **`DoubleMLLPLR` in v0.163.3**:
their `ml_m` default is now
`LearnerDispatch::logistic_regression(LogisticRegression::new())`, while
`ml_g` deliberately stays OLS (it models `E[y | x]`, not `P(y = 1 | x]`), so the
two defaults diverge on purpose. `LearnerDispatch::is_classifier()` reports
which constructors qualify.

The migrations do NOT all have the same margin, and the gates are shaped
accordingly. `DoubleMLIRM` on a saturated-propensity fixture (true `ATE = 1.5`)
across three seeds: default recovers within `0.198`, an OLS propensity misses
by at least `72.8` -- a 366x separation on the coefficient. `DoubleMLAPO`
(true `E[Y | D=1] = 1.2`): default within `0.531`, OLS misses by as little as
`5.246` -- only ~10x. APO's standard error is the honest discriminator
(`0.270` vs `86.28`, a 300x separation), because the mechanism is that an
unbounded propensity makes `1 / m_hat` explode and takes the variance with it.

`DoubleMLSSM` has the largest margin of the four, because its score carries
**two** reciprocals, one per direction (`ssm.mbt:73-74`): the treatment
propensity `m` and the selection propensity `pi`, so an unbounded regressor
breaks both denominators independently. On a saturated fixture with true
`theta = 1.0`, the OLS arm returns `242.116` with SE `185.45` where the
classifier returns `1.177` with SE `0.0982` -- roughly **200x** on the point
estimate and **1900x** on the standard error. Across three seeds the OLS
coefficient also **changes sign** (`+242`, `+106`, `-452`); the classifier's
spread over the same three seeds is `0.761`.

One caveat worth stating plainly: on a *mild* fixture, where the true
propensity never reaches the `0.02`/`0.98` clamp, the two learners agree to
three decimals and OLS is marginally better. The hazard is a property of the
clamp, not of the estimator in general, and the gate suite pins both regimes so
a future change cannot be scored on the flattering fixture alone.

**Eight structs still default `ml_m` to `linear_regression()`**:
`DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`,
`DoubleMLDIDCrossSection`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
`DoubleMLDIDMulti`, `DoubleMLIIVM`. Until each is
migrated, pass a classifier explicitly:

```moonbit
ml_m = LearnerDispatch::logistic_regression(LogisticRegression::new())
```

`LearnerDispatch::RandomForestClassifier` and
`LearnerDispatch::GradientBoostingClassifier` are the nonlinear options.

**The hazard is NOT uniform, and was measured per-estimator** (v0.132.0-v0.142.0).
Migrating `DoubleMLDIDBinary` was attempted and abandoned on the evidence:
across four probe designs and ~14 configurations its OLS default matched a
logistic one to within ~1e-4, and where they differed the OLS default was the
BETTER of the pair. The reason is structural. In the observational DID score
(`did.mbt:708`) `w_d = d_i / m_i`, so `1 / m` enters **only for treated
rows** (controls get `w_d = 0`), and the score is **doubly robust** -- a
correct `g` carries identification, leaving `m` second-order. IRM and APO need
`m` for the estimand itself, which is why they showed a ~200-point error and
DID shows ~0.001. The sharpest DID case: at n=200 the CLASSIFIER default is
worse on both bias (0.0776 vs 0.00050) and SE.

| Estimator | OLS default | Evidence |
|---|---|---|
| `DoubleMLIRM` | hazardous | coef `-225.86` vs `1.44` |
| `DoubleMLAPO` | hazardous | bias `5.246` vs `0.531`; SE `86.28` vs `0.270` |
| `DoubleMLAPOS` | hazardous | per-level bias to `436.11` |
| `DoubleMLDIDBinary` | **not demonstrated** | 4 designs, ~14 configs, ~1e-4 |
| `DoubleMLDID`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti` | not demonstrated | doubly robust -- `1/m` enters treated rows only |
| `DoubleMLSSM` | **hazardous -- fixed in v0.138.0** | coef `242.116` vs `1.177` |
| `DoubleMLCVAR` | not demonstrated | `2.300` vs `2.373` |
| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | frozen at `-1.583` for tau 0.50-0.90 |
| `DoubleMLIIVM` | not demonstrated | `0.987` vs `1.031` (16x *smaller* SE) |
| `DoubleMLPLR` | not demonstrated | `1.015` vs `1.103` -- OLS better |
| `DoubleMLLPLR` | **not demonstrated -- root-caused in v0.140.0-v0.142.0** | not an `ml_m` hazard; two failure modes; see below |
| `DoubleMLPQ` | **hazardous -- fixed in v0.139.0** | ignored its `quantile` entirely |

Every row above is a **measured verdict**, and each was settled in the release
that decided it: `DoubleMLIRM` (v0.132.0), `DoubleMLAPO` (v0.134.0),
`DoubleMLAPOS` (v0.135.0) and `DoubleMLDIDBinary` (v0.136.0) first, the rest
in v0.137.0. `DoubleMLQTE` is the one row whose verdict is later than its
measurement: v0.137.0 recorded it as *not demonstrated* (`0.162` vs `0.249`),
and the freeze was only found in v0.139.0. **Six rows turned out hazardous**:
`DoubleMLIRM` (`-225.86` vs `1.44`), `DoubleMLAPO` (bias `5.246` vs `0.531`),
`DoubleMLAPOS` (per-level bias to `436.11`), `DoubleMLSSM` (`242.116` vs
`1.177` -- its score divides by `m*pi` AND `(1-m)*pi`, two reciprocals in both
directions, `ssm.mbt:73-74`), and `DoubleMLPQ` / `DoubleMLQTE`, which ignored
their `quantile` outright. All six default to a classifier today.
`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR` (whose
propensity role is `learner_m`, not `ml_m`) kept their OLS default **on
measured evidence** -- no flip was warranted.
`DoubleMLLPLR`'s degenerate standard error is real and was root-caused in
v0.140.0, but it is **not** an `ml_m` defect -- see the note below.

A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces all four earlier outcomes
-- but `DoubleMLIIVM` **refuted** it, carrying `1/m` and `1/(1-m)` on every row
and still measuring harmless. A reciprocal in the score is not sufficient for
the hazard; the classifier is a way to decide what to measure first, nothing
more.

> **`DoubleMLPQ` IGNORED its `quantile` argument on the default path -- fixed in
> v0.139.0.** An ordinary caller who never mentioned `ml_m` got the identical
> coefficient at every tau:
>
> | tau | old default (OLS `ml_m`) | shipped now |
> |---|---|---|
> | 0.10 | -0.38571498836568785 | -0.38571498836568785 |
> | 0.25 | **-0.38571498836568785** | 0.5268291897597495 |
> | 0.50 | **-0.38571498836568785** | 0.9570929867084059 |
> | 0.75 | **-0.38571498836568785** | 1.2753280162498020 |
> | 0.90 | **-0.38571498836568785** | 1.2753280162498020 |
>
> Cause: `score[i] = treated[i] / m[i] * 1{y[i] <= theta} - q`
> (`quantile.mbt:127`) with `m` clipped to `[propensity_clip, 1 - propensity_clip]`
> (`quantile.mbt:175-177`). An unbounded regressor propensity predicts outside
> `[0,1]`, so treated rows saturate at `m = 1e-6` and carry weight `1e6`; the
> IPW distribution is then dominated by whichever rows saturated and its
> tau-quantile is the same for every `q in (0,1)`. `DoubleMLQTE` shares
> `solve_pq`, and did freeze too -- at `-1.5829876410256796` for tau 0.50-0.90.
>
> **Every PQ test that existed passed `quantile=0.5`**, so nothing could catch
> this. `expand_v139_test.mbt` now sweeps five taus on the shipped path across
> two fixtures, counting changed steps with *exact* inequality -- the defect is
> an exact tie, and a tolerance would hide it.
>
> **The residual tie at tau 0.75 / 0.90 is a PLATEAU COLLISION, not a freeze**
> (root-caused in v0.143.0). The score is a **step function** of theta:
> `iy = if y[i] <= theta { 1.0 } else { 0.0 }` (`quantile.mbt:126`), so
> `mean(psi)` is constant between observed outcomes. Two taus whose crossings land
> on the same step get the same root. Measured in a 0.05-wide window around the
> tied value: **25 distinct plateaus**, longest flat run **62 of 400** grid steps.
>
> Two explanations were tested and **both refuted**:
>
> 1. *A gap in the weighted distribution* -- no. At seed 17 the treated outcomes
>    are **1033 of 1033 distinct**, 0.75-quantile `3.2723` vs 0.90-quantile
>    `3.8917`, about 155 observations apart.
> 2. *QTE ties where PQ does not* -- no. Across four seeds, **both** tie at seed
>    17 (`1.275328016249802` each) and **neither** ties at seeds 23, 29 or 41. The
>    v0.139.0 contrast was reading one fixture as an estimator difference.
>
> And it resolves as the sample grows, which is what a plateau collision must do:
>
> | n | coef @ 0.75 | coef @ 0.9 | tied |
> |---|---|---|---|
> | 1000 | `1.4491898789269633` | `1.4491898789269633` | **yes** |
> | 2000 | `1.275328016249802` | `1.275328016249802` | **yes** |
> | 4000 | `0.9570929867084059` | `1.3732758716025382` | no |
> | 8000 | `1.4356301994178935` | `1.7559108756022739` | no |
>
> More distinct outcomes means more steps, so two taus are less likely to share
> one. A solver defect would not behave this way. **Nothing is patched**: removing
> it would mean smoothing the indicator, which changes results in the healthy
> region to suppress correct behaviour.
>
> This is NOT the v0.137.0 defect, which froze the coefficient at **every** tau
> (`0 of 4` distinct steps) and is fixed.

> **`DoubleMLPQ` reported the IPW root while publishing the orthogonal score --
> fixed in v0.159.0.** A different defect from the two above, and the only one
> that made the estimator *silently self-inconsistent*.
>
> `solve_pq` bisected the **IPW** score and returned that root as the
> coefficient, then built `psi` from the `g` cross-fit. Those are two different
> functionals of the data, so the number reported did not satisfy the estimating
> equation the estimator itself publishes. Measured on a continuous-confounding
> DGP: the reported coefficient's own orthogonal score averaged **`-0.224968`**.
>
> Upstream (`doubleml` 0.11.3) is explicit that the IPW root is PRELIMINARY.
> `pq.py:378` solves it **only** to build `g`'s target (`pq.py:390` fits
> `ml_g(x_treat, y_treat <= ipw_est)`); `pq.py:423` then sets
> `_coef_start_val = mean(ipw_vec)`, and `double_ml_score_mixins.py:149` runs
> **Newton from there** against the orthogonal score `pq.py:268`. The reported
> coefficient is that root. `DoubleMLQTE` shares `solve_pq` and inherits it.
>
> Both halves matter, and the second half is the one that bites. The score
> contains `1{y <= theta}` -- the same step function the plateau collision
> above is built from -- so `mean(score)` is piecewise constant and **a
> bisection converges onto a jump, not a zero**; the midpoint of a jump is not
> a root. That is what upstream's Newton avoids. The `deriv` likewise must not
> be a central difference of a step: it is identically zero wherever no
> observation lies within `+/- h`, `fit` scales `psi` by `1/deriv` unguarded
> (`quantile.mbt:2427-2429`), and `0/0 = NaN` reaches `ses`. Measured
> `ses = [NaN, 0.3019, 0.1758, 0.1994, 1.6937]`. Upstream's `_compute_score_deriv`
> is a **Silverman-bandwidth weighted Gaussian KDE**, which is positive
> everywhere, so this is structurally unreachable rather than merely unlikely.
>
> | | before | after |
> |---|---|---|
> | reported root | IPW | orthogonal (Newton from IPW root) |
> | `mean(psi)` at the `DoubleMLPQ` coefficient | `-0.224968` | **`-0.0032`** |
> | `deriv` | central difference, can be `0` | Silverman KDE, strictly positive |
>
> Two numbers, and conflating them is its own documentation defect. `solve_pq`
> returns the Newton root (`2.233784152367102`, `mean(psi)` at that root
> `+0.0028`), while `DoubleMLPQ::fit()` reports the coefficient
> (`2.230920809568266`, `mean(psi)` there `-0.0032`). They differ by `2.9e-3`
> and both are correct, because they answer different questions.
>
> On a DGP whose `Q_0.6(Y(1)) = 2.2` holds **by construction** (confounding
> enters `Y(0)` only), `theta = 2.230920809568266` with `se = 0.044753173108603286`,
> so the error `0.0309` is inside one SE. Newton moves theta only `0.0021` from
> the IPW root, which is the point: upstream treats that root as a **start
> value**, not the answer.

When you pass a classifier explicitly, name it on BOTH sides of any comparison: a
gate phrased against "the default" silently changes subject when the default
moves (hit four times across v0.134.0-v0.136.0).

> **`DoubleMLLPLR` can return a degenerate standard error -- and it is NOT an
> `ml_m` default problem.** Root-caused in v0.140.0. On the reference
> Liu-Zhang-Zhou 2021 design (`make_lplr_LZZ2020`, `dgp_lplr.mbt:37`) with a
> large true coefficient, both learners collapse to coef `~ -10` with SE `~ 1e-6`
> and a five-decimal confidence interval that EXCLUDES the truth:
>
> | true alpha | `ml_m = linear_regression` | `ml_m = logistic_regression` |
> |---|---|---|
> | 0.50 | `0.6636` / SE `0.1954` | `0.6293` / SE `0.1684` |
> | 0.75 | `1.3573` / SE `0.3861` | `1.2161` / SE `0.2993` |
> | 1.00 | **`-10.1863` / `1.39e-6`** | `2.9981` / SE `1.8142` |
> | 1.25 | **`-10.0567` / `1.62e-6`** | **`-10.4075` / `1.03e-6`** |
> | 2.00 | **`-9.0852` / `5.22e-6`** | **`-9.9926` / `1.93e-6`** |
>
> Across three seeds per cell, the regressor arm is degenerate at 3/3 for
> `alpha >= 1.0` and the classifier arm at 3/3 for `alpha >= 1.25`. The
> classifier **delays** the failure by roughly one step and then fails
> identically, so passing it explicitly is not a workaround.
>
> Cause, read from the source and confirmed by measurement:
>
> 1. `prelim_beta_per_fold` (`lplr.mbt:71-95`) returns `beta` built from
>    `w = ln(m / (1 - m))` -- the logit of the fitted propensity. As the effect
>    grows, `w` grows and `exp(r_hat)` in the score (`lplr.mbt:198-204`) reaches
>    `O(1e3)`. Measured at `alpha = 1.25`: `mean(psi) = 1097.07` and
>    `mean(psi_deriv) = -1097.07` -- the same order on BOTH arms, cancelling.
> 2. The Newton convergence flag WAS computed and **discarded** --
>    `let _ = converged`, now only documented at `lplr.mbt:885`; v0.145.0
>    replaced the bare flag with a `stop_reason` string (`lplr.mbt:887`).
>    With the step clamped to `0.25`
>    (`:853-854`), 50 iterations cannot span an arbitrary distance, so the loop
>    can stop away from the root, and `fit` computes a coefficient and a
>    variance there with no error raised.
> 3. `se = sqrt(gamma / (j*j*n))` with `j = mean(psi_deriv)`
>    (`var_est.mbt:52`). A huge `j` from step 1 makes the variance collapse.
>
> So the default keeps its regressor -- changing it would be the v0.136.0
> mistake again, trading a working default for a rationale that measurement
> does not support while leaving the cause untouched.
>
> **v0.141.0 / v0.142.0: in the degenerate region the objective is ROOTLESS.**
> Sweeping `mean(psi)` over `theta` in `[-30, 30]` and counting sign changes:
>
> | true alpha | sign changes | result |
> |---|---|---|
> | 0.50 | 1 | healthy -- a root exists |
> | 1.00 | 1 | degenerate anyway (the solve misses the root it has) |
> | 1.25 | **0** | degenerate -- **no root anywhere in range** |
>
> v0.141.0 said "the objective has no root" without qualifying the region; that
> was too strong and is corrected here. The accurate statement is that it is
> **rootless for `alpha >= 1.25`**, which is exactly the degenerate region. At
> `alpha = 1.0` a root does exist and the solver still fails to reach it -- so
> there are two distinct failure modes, not one.
>
> Every degenerate cell lands at `-8.3` to `-10.5` (mean `-9.85`) **while the true
> effect ranges 0.75 to 2.0** -- an output that does not move when the estimand
> moves by 2.7x.
>
> Three candidate fixes were measured and **all three were refuted**:
>
> 1. *Bound `t_pred`* -- degeneracy is uncorrelated with its range. A cell with
>    `t_pred` in `[-2.86, 4.16]` is degenerate; a cell reaching `+6.93` is
>    healthy.
> 2. *Rewrite the score in bounded form* -- `psi_hat * exp(r_hat) == expit(r_hat)`
>    looks like free numerical hygiene and **is not an identity here**: measured
>    `max_abs_diff = 0.546` and relative difference up to **0.92** on healthy
>    fixtures. Shipping it would silently change every LPLR result.
> 3. *Use a classifier for the `t` stage* -- **aborts** at `logistic.mbt:206`,
>    because that stage regresses on `w_inner = ln(m/(1-m))`, a continuous
>    unbounded logit propensity, not a 0/1 label.
>
> Where the objective is rootless (`alpha >= 1.25`), iteration budget, damping,
> start value and clipping are all inert; that case needs reparameterising the
> **objective** (a bounded link such as `expit`), which moves every LPLR result
> and is a model rewrite rather than a bug fix. Where a root exists but is missed
> (`alpha = 1.0`), solver quality genuinely is the issue.
>
> The diagnostic that settles which case you are in is cheap and general:
> **count sign changes of the objective over a wide parameter range before
> touching the solver.**
>
> **Port-vs-upstream (v0.142.0), recorded because fidelity alone would mislead:**
> the score formula is byte-identical to upstream (`lplr.mbt:194-204` vs
> `lplr.py:401-418`, including `exp(-coef*d)`), but two things differ.
> Upstream keeps `beta` **row-wise** (`lplr.py:315-346`) while this port folds it
> to one scalar (`lplr.mbt:866`). That is a real divergence -- but adopting
> upstream's per-row shape makes the root **worse** (1 -> 0 sign changes at
> `alpha = 1.0`), so it is not the cause and must not be changed on fidelity
> grounds. Upstream also handles solve failure in
> `double_ml_score_mixins.py:143-162` (brentq fallback on bounds; a warning or
> `ValueError` on non-convergence). This port omits that path entirely --
> `let _ = converged` (`lplr.mbt:885`) -- which was the one clear, low-risk
> divergence available to fix, and which v0.145.0 took.

**`DoubleMLAPOS` honoured a configured `ml_m` everywhere except where it
counted (fixed in v0.133.0).** Its `fit` path built each child
`DoubleMLAPO` without forwarding `ml_g` / `ml_m`, while `bootstrap` and both
sensitivity paths did. Passing `LogisticRegression` to `DoubleMLAPOS` returned
`coefs()[0] = -201.32` on a fixture whose true ATE was `1.2` -- bit-identical
to ignoring the argument, and 203 points from the same learner applied
directly. Nothing raised. The defaults listed above are unchanged; this was a
plumbing fix, and the two are deliberately separate so a failing test can be
attributed to one or the other.

**Propensity-score processor (`PSProcessor`)** -- `clipping_threshold`
clipping, isotonic (PAVA) calibration, K-fold cross-validated (CV)
calibration. Plugs directly into `DoubleMLIRM` / `DoubleMLIIVM` /
`DoubleMLDID` and the rest of the IPW-based models.

> **Two PSProcessor defects fixed in v0.159.0.** Both were silent.
>
> **Isotonic calibration collapsed on tied `x`.** `fit_isotonic` ran PAVA over
> the raw sorted sequence **without first pooling observations that share an
> `x`**. An isotonic regression is a *function of x*, so ties must receive one
> shared fitted value; instead `predict_isotonic` resolved each tie to the LAST
> index of the run, and the `[0.01, 0.99]` clip turned the stray `1.0` into
> `0.99`. The reported case -- predictions `[0.5, 0.5]`, labels `[0, 1]` --
> returned `[0.99, 0.99]` where sklearn 1.9.0's `IsotonicRegression` gives
> `[0.5, 0.5]` with `y_thresholds_ = [0.5]`. The fix adds `pool_tied_x` and
> passes the group **size** to `pava` as a weight, because the L2 objective is
> over observations and the group statistic is therefore a size-weighted mean.
> `pava` itself is unchanged. A tie-free control is unchanged, which is what
> shows the pooling is what moved the tied case.
>
> **`cv` was never forwarded, so `cv_calibration=true` calibrated on the wrong
> split.** `adjust_ps` *declares* a `cv` parameter and upstream passes
> `cv=smpls` at every call site (`pq.py:410`, `did_binary.py:537`,
> `iivm.py:371`, `cvar.py:343`), but in this port **no estimator ever passed
> it**. With `cv_calibration=true` the processor silently calibrated on its own
> `default_5fold(n)` -- five *contiguous* blocks -- instead of the estimator's
> `n_folds` partition. Now wired at `irm.mbt:430` and `iivm.mbt:525` via
> `folds_to_cv_partition`, which is sound because `kfold`'s `Fold` guarantees
> disjoint test indices covering `[0, n_obs)` (`kfold.mbt:199`).
>
> Note this is **narrower than "IRM/IIVM has no hookup"**, which was measured
> and found too strong: the isotonic config *did* already reach both fits. The
> `adjust_ps` call sites that do not forward `cv` are **eight**, in seven
> files: `apo.mbt:320`, `cvar.mbt:736`, `cvar.mbt:1005`, `did.mbt:628`,
> `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `quantile.mbt:217` and
> `ssm.mbt:671`. The only two that do are IRM's and IIVM's -- `cv=` is passed
> at `irm.mbt:430` and `iivm.mbt:525`.

**`ps_processor_config` is reachable (v0.121.0+, IRM v0.122.0, IIVM and SSM
v0.123.0, PQ v0.124.0, LPQ v0.125.0, CVaR v0.126.0, DID v0.127.0, CS-DID
v0.128.0).** `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLIRM`, `DoubleMLIIVM`,
`DoubleMLSSM`, `DoubleMLPQ`, `DoubleMLLPQ`, `DoubleMLCVAR`, `DoubleMLDID`,
`DoubleMLDIDBinary`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection` and
`DoubleMLDIDCS` now take a `PSProcessorConfig`, which is how the isotonic
and CV-calibration paths become callable from an estimator at all --
until v0.121.0 they were implemented and reachable from nowhere.
Resolution follows upstream's `init_ps_processor`: **the config wins
outright** and the deprecated scalar `propensity_clip` is read into it
only when no config is supplied. Measured against upstream 0.11.4, the
calibration is not cosmetic -- isotonic moves the propensity by up to
0.53 on the test fixture, the APO coefficient moves from
2.9641677613312316 to 2.9602088935501736, the IRM coefficient from
1.9609911300451515 to 1.9603016544875, and the CVaR coefficient runs
3.664307496539196 -> 3.3179262532001292 across the clip sweep (isotonic
lands at 3.471229424883473). CVaR is worth singling out because it is the
first estimator here whose estimate is *genuinely* a weighted quantile:
LPQ's root is pinned by its bisection bracket, so no threshold could move
it, while CVaR solves `mean(treated/m * 1{y <= theta}) = quantile` and
therefore does move.

Six details worth knowing before wiring it yourself. First, which array
is the calibration target differs by estimator, and upstream is not
uniform: `DoubleMLIIVM` passes the **instrument `z`**, not the treatment
`d` (`iivm.py:371`), because `m` is the propensity *of the instrument*;
`DoubleMLPQ` passes `treated`, the indicator it actually regresses on.
Second, `DoubleMLSSM` adjusts `m` only -- its selection propensity `pi`
is clipped but **never calibrated**, matching upstream (`ssm.py:407` vs
`ssm.py:414`). Third, on `DoubleMLLPQ` this port deliberately does
**not** overwrite `propensity_clip` with the config threshold the way
upstream does (`lpq.py:166`), because that scalar also floors the
estimated complier share here; upstream has no such floor, and where it
bites the two diverge by 4.2x. On `DoubleMLCVAR` the *opposite* choice is
made and is correct: upstream redirects the scalar to the config's
threshold (`cvar.py:156`) and so does this port, because all three of its
uses -- the preliminary clip, the final clip, and the re-clip inside
`sensitivity_analysis` -- are that same threshold and there is no second
job for it to disturb. Note also that CVaR's two `adjust_ps` sites take
*different* second arguments: the preliminary one is `d_train_1`
(`cvar.py:293`), the final one is the full `d` (`cvar.py:343`), and
swapping them aborts on `adjust_ps`'s length precondition. The third use is
worth a caveat -- `irm_style_sensitivity` has no `psi_b` parameter, so the
`psi_b` CVaR computes there is discarded and `propensity_clip` cannot reach
the returned `SensitivityResult` by any route. That is pre-existing, and
`v126_sensitivity_reclip_is_structurally_inert` pins it. Fourth, `adjust_ps`
requires a **binary**
treatment; `treatment_is_binary` is public if you want to check first. Fifth,
on `DoubleMLDID` / `DoubleMLDIDBinary` the resolution deliberately does **not**
read `propensity_clip`. Upstream's deprecated scalar there is
`trimming_threshold`, defaulted at `1e-2` (`did_binary.py:123`), and this
port's `PSProcessor::new()` also defaults to `1e-2` -- but this port's
`propensity_clip` defaults to `1e-6` and is read **only** by the inner
`cross_fit_did`'s `clip_vec`, a numerical-safety clip with a genuinely
different job. Redirecting it would silently turn the default public clip
from 1e-2 into 1e-6. So with no config supplied the stored threshold stays
`1e-2` whatever `propensity_clip` says, and the two knobs stay independent.
That family also has just **one** `adjust_ps` site (`did_binary.py:537`), and
that ATT responds much more strongly on the raw `DoubleMLDID` (spread 2.25e-2
across the clip sweep) than through the panel wrapper (1.8e-3, a 12x
damping), so the wrapper's gate is written as an exact inequality rather than
a threshold. Sixth, `DoubleMLDIDCSBinary` deliberately uses the group
indicator `G` for **both** its propensity regression and its `adjust_ps`
calibration -- so it models `P(G=1|X)`, not `P(D=1|X)`. That is **correct**,
and v0.128.0 got it wrong. Upstream's local variable at
`did_cs_binary.py:504` and `:516` is spelled `d`, but it is bound at `:472` to
`self._g_data_subset`, and that line's own trailing comment reads
`# (d is the G_indicator)`. The trap is that the data column is *also* called
`d`, and on a staggered design the two differ on 109 of 720 evaluated rows
(the two fits disagree by up to 0.365) -- so the substitution is large and
visible, and still correct. Confirmed at runtime by capturing the arguments
at both upstream call sites (`_verify/_oracle_1290.py`), not by reading names.
The invariant is stronger than a comment: **nothing in
`DoubleMLDIDCSBinary`'s fit path reads `data.d`**, so scrambling the treatment
column must leave the estimate bit-identical --
`v129_cs_binary_never_reads_the_treatment_column` pins exactly that, and
`v129_cs_binary_nuisance_is_a_group_propensity_like_upstream` keeps the
fixture premise. `DoubleMLDID` (panel) and `DoubleMLDIDCrossSection` do use
the real `D`, because upstream's counterparts there do
(`did.py:197` reads `self._dml_data.d`).
Seventh, and fixed in **v0.130.0**: `DoubleMLDIDCSBinary::sensitivity_analysis`
used to read `self.data.y[i]` and `self.data.d[i]` — the **full 1080-row
panel**, indexed at **subset** positions, with the per-period treatment rather
than `G`, and with a 2-way `y - g00 - (g10 - g00)*d` form that always used the
`T = 0` g-function. Upstream uses the subset's own `y`/`G`/`T_indicator`
(`did_cs_binary.py:845-866`) and mixes the four `(G, T)` cells. Measured, **240
of the 720 rows read had `t == 1`** — a period the subset never contains, and
the one in which `y` carries the treatment effect. `sigma2` came out **583x**
too large (1.1473 vs 0.00197), and **no test in the package exercised the
function at all**. `irm_style_sensitivity`'s `require(n == psi_a.length())`
guard passed throughout, because both arrays were length 720 while describing
different observations. Fixed, and both entry points now share one builder
(`cs_bin_sensitivity_residuals`) so they cannot drift apart again.

**THE RECOVERY TOLERANCE, and the `t_pre` defect it uncovered** -- v0.152.0.
v0.150.0 made `dgp_recovery_test` non-vacuous but left its band untouched: an
absolute `max_abs_err < 5.0`, inherited from before the fix and never examined.
It was wrong in both directions at once.

Measured across 12 seeds on `make_did_cs_CS2021(800, 3, 1.0, seed)`:

    max |att - 1.0|            14.41   <- the band FAILS on seeds 7, 77, 314
    max |att - 1.0| / se        2.41   <- in SE units the error IS bounded
    se range          0.589 .. 8.837

So `5.0` was TOO LOOSE -- at the tested seed it permits 2.9x the error the
estimator actually makes -- and TOO TIGHT: it rejects a quarter of the seeds, and
it rejects them for being CORRECT. At seed 314 the estimate is 6.5136 +/- 6.8728,
i.e. z = 0.802, an entirely ordinary answer the absolute band calls a failure.
The error is large precisely when the SE is large, which is what a correctly
scaled robust SE is for. The band is now `|att - 1| < 5 * se`, 5 chosen against
a measured worst case of 2.41 -- the same 5 the sibling DIDMulti test already
used. The point estimate and SE are ALSO pinned exactly at 1e-12 relative,
because with a fixed seed that is the stronger statement and catches drift a
relative band would forgive.

**`DoubleMLDIDMulti` ignores `t_pre`.** The test that runs on `make_did_CS2021`
was named `DIDMulti_DGP_estimator_recovers_some_ATT` and constructs
`DoubleMLDIDCS`. So `DoubleMLDIDMulti` -- the class that owns
`gt_combinations` and is the documented consumer of that DGP -- has NO recovery
test anywhere in the package, and the name made the gap invisible. Renamed here
rather than left claiming coverage it never had.

Why there still isn't one is a blocker, not an oversight. The API takes
`(g, t_pre, t_eval)` triples and promises control of the base period;
`coef_at_idx` calls `ignore(t_pre)` and the inner derives its own base as
`g - 1`. The proof is one line -- `(1, 0, 2)` and `(1, 1, 2)` return the
IDENTICAL coefficient 0.6790989134518333. And that makes the DGP unusable for
validating DIDMulti: `make_did_CS2021` treats cohort `g` at `tau_g = g - 1`, so
the inferred base IS the first treated period. Measured against a true theta of
1.0: 1.4166 / 0.6791 / 0.3153 / -2.3785 / -1.2812 / -10.5035. A recovery test on
those numbers would enshrine the bug.

4 gates added (`expand_v152_test.mbt`). GATE 2 pins that the old band WOULD have
failed, asserting `z < 1.0` alongside `err > 5.0` so the seed that breaks it is
demonstrably a good estimate -- which is what stops the change being reverted on
the grounds that `5.0` "was always fine". GATE 4 pins `t_pre`'s inertness as a
DECLARED DEFECT WITH A TRIPWIRE: it will fail the moment `t_pre` is honoured, at
which point it is inverted rather than deleted.

Mutation 3/4, and both survivors/results are worth reading. M4 (the stored SE
inflated 10x) confirmed a weakness I predicted in advance: an SE-relative band
DIVIDES by the SE, so inflating it drops z tenfold and every recovery gate still
passes. The band is one-sided -- it can catch a coefficient too far from the
truth in units of its own SE, never an SE that is too large. What caught M4 was
GATE 3's exact pin, so the release is not relying on the band alone.

M3 (`di` dropping its time condition) survived, and the first instinct is to
call that blindness. It is not: measured against baseline the canonical cell is
BIT-IDENTICAL on all three seeds -- coef and se agree to the last digit. A
mutant that cannot move a number cannot be caught by an assertion about that
number. The limitation is the FIXTURE, not the gates: a 2-period panel with a
single post-treatment cell cannot distinguish that relabelling. Recorded rather
than papered over with a tighter threshold.

Also caught by running all four targets, again: the `t_pre` gate's literal was
pinned with `==` and passed native while failing wasm AND wasm-gc -- the same
~1.5e-15 cross-backend spread as v0.150.0. The inertness assertion `base0 ==
base1` KEEPS its `==`, because both values come from the same backend and a
difference there would mean the base period mattered. Only the literal moved to
1e-12 relative. Native green is not evidence. Four targets, always.

Tests: 1087 native / 1087 wasm / 1093 wasm-gc / 1087 js, all four green.
213 .mbt files (65 production + 123 blackbox test + 25 whitebox test).

Still open: honouring `t_pre` is a real API defect, not a test gap, and it blocks
DIDMulti recovery testing until fixed. The port's cell-grid divergence from
upstream is unchanged.

**THE `alpha_i` RAMP IN `make_did_CS2021` -- the one v0.148.0 missed** -- v0.151.0.
v0.148.0 removed `alpha_i = 0.5 * unit_in_cohort` from `make_did_cs_CS2021` and
never applied the fix to its 4-cohort sibling. Same defect, same reasoning,
different file.

Measured before, on `make_did_CS2021(1600, 3, 1.0, 3141)` where
`n_per_cohort = 1600/4/4 = 100`:

    var(y)                                  206.75   (SD 14.38)
    corr(id, y)                               0.975
    r^2 X_0 / X_1 / X_2 vs y     1.0e-5 / 2.6e-3 / 9.2e-3
    share of var(y) that is time-invariant     99.65 %
    var(within unit)                            1.11

`0.25 * var(0..99) = 208.3` against a total of 206.75: THE RAMP WAS THE
VARIANCE. It is not even cohort-specific noise -- `unit_in_cohort` repeats in
every cohort, so it is a positional ramp. Covariates carried under 1% of the
outcome, exactly the condition v0.148.0 called out as making the did_cs
sensitivity migration untestable. After the fix: `var(y)` 11.06,
`corr(id, y)` -0.108, `r^2` 0.423 / 0.647 / 0.560.

A per-unit N(0,1) DRAW rather than deletion: unobserved unit heterogeneity IS the
hidden confounding `nu2` exists to price, so removing the term outright would
leave the fixture unable to represent what it is for. The draw is taken AFTER
the noise stream, so X and `eps` are untouched -- and the evidence that this
worked is that `var(within unit)` is BIT-IDENTICAL across the change
(1.1087561532787724 -> 1.1087561532787722), so the `r^2` columns moved only
through alpha's own contribution.

**8 gates added (`expand_v151_test.mbt`), and three of them exist only because
mutants survived.** GATE 0 asserts the correlation helper returns 1.0 against a
variable and itself, since every correlation gate is worthless if the measuring
routine is broken. GATE 1 pins covariate `r^2 > 0.35`; GATE 2 pins
`|corr(id, y)| < 0.25`; GATE 3 states the ramp's absence on the quantity the ramp
keyed on, the unit-level mean of `y` not being monotone in `unit_in_cohort`;
GATE 4 pins the outcome scale and the PRESENCE of heterogeneity; GATE 5 proves
the fix touched `y` and nothing else, without which the `r^2` gain could equally
mean the treatment effect had been shrunk.

GATE 4's presence check was BLIND, and the mutation run said so. With six gates
written the first run scored 2/5 killed: M1 (`alpha_i = 0.0`, deleted),
M4 (`alpha * 0.15`) and M5 (`alpha[u / 100]`, one intercept per cohort) all
SURVIVED. The reason is structural and is the same masking that caused the
original bug: X is ITSELF unit-level and time-invariant in this DGP, so it
supplies the time-invariant share and the variance floor on its own. Any gate
reading `corr(id, y)` or a variance band cannot tell "the unit intercept is
present" from "the unit intercept is gone but X is doing its job".

GATE 6 projects X out of the unit-level outcome and looks at what is left. Since
`alpha` is drawn independently of X, that residual IS alpha (plus `eps` averaged
over four periods): measured 1.279 against the predicted
`var(alpha) + var(eps)/4 = 1.25`. That kills M1 and M4.

GATE 7 handles M5, whose TOTAL heterogeneity is unchanged and so is invisible to
GATE 6. Its first version SURVIVED M5 as well: it asserted
`within_cohort_var > 0.2` on the reasoning that a constant-per-cohort intercept
drives it to zero. It does not -- the residual floor is ~0.27 from `eps/4` and
projection error, and the mutant walked straight through. The scale-free
statement is the real one, and it is a RATIO: under a per-unit intercept the
within-cohort spread equals the overall spread, because units within a cohort
are exchangeable. Measured 1.009 / 1.279 = 0.789, against ~0.21 under M5.

Final 5/5 killed, 0 survivors, 0 inconclusive, baseline 8/8.

Blast radius: 3 sites, all value pins on this fixture -- `expand_v146_test.mbt`
GATE 5, the v0.147.0 additivity gate, and that file's four-accessor mean gate.
Every number re-measured, none guessed. Exactness was re-established per
quantity rather than assumed: `g_d1t1`'s mean is 0.7510479216157833 on all four
backends and keeps its `==`; the other three differ in the last one or two digits
and take 1e-12 relative.

Tests: 1083 native / 1083 wasm / 1089 wasm-gc / 1083 js, all four green.
212 .mbt files (65 production + 122 blackbox test + 25 whitebox test).

Still open, unchanged: DIDCS has a `(group, period)` cell grid upstream lacks, and
`make_did_CS2021` sets `tau_g = cohort - 1`, so it does not satisfy DIDCS's
g-is-treatment-period convention under either base period rule. An explicit
`tau_g` on the estimator would remove that inference.

**THE ESTIMAND FIX -- base period `g - 1`, so `ATT(g, g)` exists** -- v0.150.0.
This is the first release in this thread that CHANGES REPORTED NUMBERS; every one
from v0.146.0 to v0.149.0 was additive.

`DoubleMLDIDCS::fit` used a cohort's OWN treatment period as its pre-treatment
baseline and then required `eval_period > pre_period`, so it could only ever
reach `t > g`. The ATT in a cohort's FIRST TREATED PERIOD was never estimated on
any panel, ever. Callaway & Sant'Anna's convention is the opposite: a cohort
treated at `g` is untreated at `g - 1`, and post-treatment begins AT `g`.

On the canonical fixture `make_did_cs_CS2021(800, 3, 1.0, 3141)` the panel is
`groups = [1]`, `times = [0, 1]`, so `t > g` admitted NOTHING. `final_coef` is
zero-initialised (`did_cs.mbt:1581`), so `coef_at(0, 1)` returned the `0.0` it
was created with and `dgp_recovery_test`'s `max_abs_err < 5.0` passed on
`|0 - 1| = 1.0` -- asserting against a hardcoded zero while claiming to recover
an ATT of 1.0. Three parts of the package already disagreed with the estimator:
the fixture's own DGP treats cohort 1 from `k >= cohort`, `dgp_recovery_test`
documents `ATT(g, t)` for `t >= g`, and `did_cs_test.mbt`'s fixture sets `d` at
`k >= cohort` and then ASSERTED `coef_at(0, 1) == 0`. The estimator was the only
thing that believed `t <= g` is pre-treatment.

    coef_at(0,1)   0.0 (the sentinel)      ->  2.727522673844541
    se_at(0,1)     0.0                     ->  1.9428873717680928

On a fixture that DOES satisfy the convention (`g` is the treatment period,
effect from `k > g`), ATT is recovered to within 0.5%: `(g=1,t=2)` 0.9965,
`(g=1,t=3)` 0.9982, `(g=2,t=3)` 1.0042 against a true 1.0, and -0.0052 / 0.0094
where the true effect is 0. The canonical panel's 2.7275 +/- 1.9429 is noisy
because it is ONE cell from ONE cohort with no repeated periods to average over
-- 0.89 SE from the truth, a property of the fixture, not of the fix.

**Nine tests pinned the defect, all from one cause.** The package consistently
treated `t <= g` as "not estimable"; `expand_v100_didcs_test.mbt` even documented
it -- "An unestimated cell (`t_eval <= g`)". Rewritten or re-pinned from measured
runs. Two mattered more than a re-pin. First, `expand_v149_test.mbt` GATE 6
asserted that EVERY cell is the 0.0 sentinel, which shipped in v0.149.0 with the
defect still live: a gate certifying "nothing was estimated" is indistinguishable
from one certifying "nothing changed". Second, `se_pooled > se_single` was not a
theorem -- the cluster sandwich exceeds the IID one only under POSITIVE
within-block score correlation, and cell (0,2) inverted (0.0042918 <
0.0044041) once the rows changed. It had been asserting a property of the data.
The sign is now pinned per cell (five of six widen, (0,2) narrows), which is
STRONGER than the bare `!=` it could have been weakened to.

**A latent convention mismatch, found on the way.** `make_did_CS2021` (the
4-cohort DGP behind the v0.146.0/v0.147.0 gates) sets `tau_g = cohort - 1`, so
cohort 1 is treated from t = 0, while `DoubleMLDIDCS` interprets `g_value` as the
treatment PERIOD. That fixture satisfies DIDCS's convention under NEITHER base
period rule, and its cells were never `ATT(g, t)`: they read 0.089, -0.706,
-6.29 against a true effect of 1.0. Those gates are re-pinned and now say
explicitly that they are regression locks, NOT ATT recoveries. The same file
still carries `alpha_i = 0.5 * unit_in_cohort`, the unit-intercept ramp
v0.148.0 removed from `make_did_cs_CS2021` but never applied here.

**The new sharp edge.** A cohort whose `g - 1` is unobserved cannot have
`ATT(g, g)` estimated and is now SKIPPED rather than quietly given another base.
`v068_wbtest.mbt`'s fixture has periods 1, 2, 3 and no period 0, so cohort
`g = 1` drops out entirely. That is correct: the old rule used `t = 1` as the
base for `g = 1`, which is that cohort's first TREATED period.

5 gates added (`expand_v150_test.mbt`). GATE 1 is the one that was missing --
the `(g=1, t=1)` cell must carry an actual estimate, witnessed by a POPULATED
per-cell IF row rather than `coef != 0.0`, since a coefficient could be non-zero
by accident. GATE 2 asserts the boundary as a partition over every cell. GATE 3
is the payoff: it pins the estimator to the TRUTH on the convention-conforming
fixture, which no other gate here can do. GATE 5 pins the dropped-cohort
behaviour.

Mutation evidence 5/5 killed, and THE KILLS ALL LOOK THE SAME: every one is a
process abort (`0xc0000409`), not a failed assertion. The cause is the cursor
desync -- any mutant moving one mirrored site without the other leaves the
reassembly pass admitting a cell the fit loop never estimated, so it reads
`coef_values_acc[coef_idx]` out of an empty array. A loud abort is right for
that; the alternative is a silently wrong coefficient copied one position off.
DECLARED BLIND SPOT: no gate here is shown to catch a mutation producing a WRONG
BUT IN-BOUNDS number. A mutant altering the arithmetic while keeping both
predicates in step would survive, and I did not build one.

An exact `==` I wrote myself failed on three backends: pinning the new canonical
ATT with `==` passed native and failed wasm / wasm-gc / js, the signature of the
known ~1.5e-15 did_cs spread. Native green is not evidence. Four targets,
always.

Tests: 1075 native / 1075 wasm / 1081 wasm-gc / 1075 js, all four green.
211 .mbt files (65 production + 121 blackbox test + 25 whitebox test).

Still open, and untouched here: the port's `DoubleMLDIDCS` has a `(group,
period)` cell grid that upstream's does not -- its `_check_data` rejects a `g`
column outright -- and upstream's class is deprecated in favour of
`DoubleMLDIDCSBinary`. Separately and now visible from this release: DIDCS
infers treatment timing from `g_value`, which `make_did_CS2021` does not
honour, so an explicit `tau_g` would remove that inference.

**did_cs sensitivity, stage 2 of 4** -- v0.149.0 adds upstream's PANEL-LEVEL
`sigma2` and `nu2` as five accessors on `DoubleMLDIDCS`:
`sensitivity_sigma2()`, `sensitivity_nu2()`, `sensitivity_psi_sigma2()`,
`sensitivity_psi_nu2()`, `sensitivity_riesz_rep()`. Purely additive -- no reported
number moves, and `sensitivity_analysis` is untouched, still running
`irm_style_sensitivity` over the DML score element. The two paths disagree by
construction, and both are now exposed.

**The formulas are pinned against a RUNNING upstream, not a reading of it.** Both
were transcribed from `did_cs.py:451-497`, then checked against upstream 0.11.3,
which is installed here. On a 2x2 panel built from its own CS2021 DGP it reports
`sigma2 = 256.4070590464714`, `nu2 = 18.253043736106648`, and
`_verify/_oracle_v1482_nu2_gap.py` reproduces BOTH TO THE LAST DIGIT. A first
cross-check reported 17.325 against 18.253 and read as a 5.1% input difference.
It was neither: my oracle omitted `.ravel()`, so a 2-D `(816,1)` `m_hat`
**silently broadcast** against `(816,)` into a `(816,816)` intermediate. A 5.1%
error is exactly the size that hides a shape bug behind a tolerance.

**These are PANEL-LEVEL, not per cell.** Upstream's `_sensitivity_element_est`
reads `self._dml_data` in its entirety, and its manual oracle
`fit_did_cs(y, x, d, t, ...)` takes no `g` and has no cell loop, so both are
single scalars for the whole panel. That corrects the v0.147.0 changelog, which
implied stage 2 would produce per-cell values.

Measured on `make_did_cs_CS2021(800, 3, 1.0, 3141)`: `sigma2 = 1.8855040509678376`;
`nu2 = 21.32163562345964` with `in_sample_normalization=false` (the port's default,
upstream's is `true`); and `NaN` with `true`. The `NaN` is the informative one --
that branch divides by `mean(d1t0)`, which is `0.0` because nobody is treated in
the pre-period, i.e. the `(d=1, t=0)` cell is structurally empty, the same fact
`expand_v147_test.mbt` GATE 5 pins. Upstream's arithmetic on the same input
produces the same Inf/NaN. **No fallback is substituted**, because a quiet
replacement number is indistinguishable from a correct one.

six gates added (`expand_v149_test.mbt`; GATE 1 and GATE 2 share one test
function). The scalars are pinned at 1e-12 relative
(the did_cs quantities carry the known ~1.5e-15 cross-backend spread) and are
asserted positive and finite, since `sqrt(sigma2 * nu2)` depends on it. GATE 3
proves the `in_sample_normalization` flag selects a genuinely different branch:
`sigma2` must agree exactly, `nu2` must not. GATE 4 asserts the per-row elements
are **centred**, per upstream's convention `psi_nu2 = element - nu2`
(`did_cs.py:529`), so `sensitivity_nu2()` is deliberately NOT the mean of
`sensitivity_psi_nu2()`.

Mutation evidence 5/5, and M4 is the one that matters: storing the RAW element
under the name `psi_nu2` is the exact defect that shipped in this stage's first
draft. A raw-vs-deviation swap preserves the array's length and shape, so only a
gate asserting the **mean** can see it -- which is why GATE 4 is written that way.
I DECLARED GATE 6 a control that would survive all five and the measurement
REFUTED it: GATE 6 ends in a liveness check (`sensitivity_sigma2() > 0.0`) and is
not purely an estimate-stability check, so it fires under M5. The declaration is
corrected in the harness.

**Still open.** The port's `DoubleMLDIDCS` has a `(group, period)` cell grid that
upstream's does not, and upstream's class is **deprecated** in favour of
`DoubleMLDIDCSBinary`. This release adds the panel-level elements *alongside* the
grid rather than resolving that, so it is correct whichever way it goes. The
estimand fix (base period `g - 1`, so `ATT(g, g)` exists) is unaffected and
remains open, as does `dgp_recovery_test`'s vacuous `max_abs_err < 5.0` against
a true effect of 1.0.

**DIDCS fixture: the unit intercept was drowning the covariates** -- v0.148.0
replaces `alpha_i = 0.5 * unit_in_cohort` (a deterministic ramp to 99.5, SD
~ 28.8) with a per-unit standard-normal draw. Measured on
`make_did_cs_CS2021(800, 3, 1.0, 3141)`: `var(y)` 828.42 -> 10.76; `r^2` of each
X column against y 7e-4 -> 0.451 / 0.572 / 0.670; `corr(id, y)` ~1.0 -> -0.063;
and `mse(g_hat)/mse(cell mean)` 1.052 -> 0.185 / 0.163 / 0.190. The last row is
the one that matters: before the fix NO conditional nuisance could beat a
constant, so `g_hat` was indistinguishable from a cell mean, `sigma2 =
mean((y - g_hat)^2)` collapsed onto `var(y)`, and the did_cs sensitivity
migration had nothing to condition on and no gate able to separate a correct
`g_hat` from a wrong one. After it, the nuisance explains ~82% of within-cell
variance. A draw rather than deletion, because unobserved unit heterogeneity IS
the hidden confounding `nu2` prices; SD 1 matches the true effect `theta = 1.0`
and makes it ~19% of the covariate signal.

**One of v0.147.0's own gates broke correctly and was rewritten.** GATE 5 there
asserted `v1470_mean(a) > 1.0` to mean "populated", which was an absolute scale
smuggled in from the DGP it was written against (`y` mean 49.87). After the fix
`mean(y)` is 0.085 with sd 3.28, so it went red on a perfectly well populated
nuisance. It now asserts the scale-free property it meant: not identically
zero.

5 gates added (`expand_v148_test.mbt`). GATE 1 reads the nuisance predictions and
demands the conditional fit BEAT A CONSTANT on every populated cell (ratio <
0.25) -- the property stage 2 depends on, and the only gate there that reads
code rather than the fixture. GATE 2 pins the ramp's absence and first asserts
`corr(id, id) > 0.999999` so a broken correlation routine cannot pass silently.
GATE 3 pins covariate `r^2 > 0.35`. GATE 4 pins the outcome scale. GATE 5 proves
the fix touched `y` and nothing else (occupancy still 400/200/0/200), without
which the v0.147.0 conclusions could not have carried over.

Mutation evidence 4/4 killed. GATE 5 and every v0.147.0 stage-1b gate survived
all four, as declared -- they read occupancy. I DECLARED THAT GATE 3 survives
M2/M4 and the measurement REFUTED it: tripling the unobserved term raises total
variance without raising the covariate's share, so `r^2` falls under the floor.
The declaration is corrected in the harness, because a declared control that
turns out not to be one is worse than none.

**Estimand blocker, still open.** The canonical 2-period panel yields ZERO
estimable cells (`groups = [1]`, `times = [0, 1]`, both candidates fail
`eval_period <= g_value` because the base period is the cohort's own treatment
period), so `dgp_recovery_test`'s `max_abs_err < 5.0` against a true effect of
1.0 is still vacuous. The estimand fix (base period `g - 1`) is next.

**did_cs sensitivity, stage 1b of 4** -- v0.147.0 adds the four upstream
`(d, t)` outcome nuisances `g_dXtY = E[Y | D=d, T=t, X]` on the long panel, as
FOUR NAMED accessors `predictions_g_d0_t0()` / `_d0_t1()` / `_d1_t0()` /
`_d1_t1()` on `DoubleMLDIDCS`, plus `cross_fit_predict_conditional_dispatch` in
`learner.mbt` mirroring upstream's `fit_predict(..., train_cond=...)`
(`doubleml/tests/_utils.py:33-45`). Upstream's `sigma2` needs `g_hat` assembled from
all four (`did_cs.py:445-449`, `456-461`); the port had two, split by `d` alone
and taken from each cell's child `DoubleMLDIDBinary` restricted to its own
subset -- a different object that cannot be reassembled on the full panel.

**Four names, not a 4-tuple, and measurement is why.** The obvious design is one
`predictions_g_d()` returning `(d0t0, d0t1, d1t0, d1t1)`. Two probes ruled it
out. First, the obvious discriminator does not exist: cell-wise RMSE has no
minimal diagonal -- `g_d0t1` beats `g_d0t0` on cell `(d0,t0)` -- because RMSE
~14 is dominated by noise while the four conditional means differ by under 2.
Second, nothing else sees a permutation either: all four arrays have length `n`,
are all finite and all vary, so a swapped return literal passes every
length/finiteness/variation gate while quietly building the wrong `g_hat`. With
four names the permutation is not expressible.

**The cells are `t` in {0,1}, settled from upstream's source.** Extending them
to later periods would be a NEW modelling decision, not a port.
`did/tests/_utils_did_cs_manual.py` selects `intersect1d(where(d == 0), where(t
== 0))` and three siblings; `dgp_did_CS2021.py:309` sets `"t":
time_matrix.flatten()`, so upstream's `t` IS the period; and `doubleml/tests/_utils.py:33-45`
intersects the condition with the training index and then predicts on the whole
test fold, so the condition gates FITTING, not prediction. Upstream's
`DoubleMLDIDCS` is therefore the 2x2 repeated-cross-section design (its
multi-period sibling is `DoubleMLIDMulti`). On the canonical 2-period panel this
is an exact transcription; on a longer panel -- which this port permits and
upstream does not -- rows with `t >= 2` train none of the four, reproducing
upstream.

**Purely additive -- no reported number moves**, asserted by GATE 4. A draft of
GATE 1 that asserted array LENGTH was discarded before shipping: the helper
pre-sizes its output to `n`, so restricting *prediction* to the cell still
returns four arrays of length `n`. GATE 1 now asserts COVERAGE (measured: zero
exact `0.0` entries anywhere on the 4-period panel, versus 1300/1400/1500/1400
under that mutation). GATE 7 pins one measured mean per named accessor and
restores exactness where available: `g_d0t1`, `g_d1t0`, `g_d1t1` are
bit-identical on all four backends and asserted with `==`; only `g_d0t0` differs
(js ends `...4715` vs `...472`, ~2e-16) and alone carries a 1e-12 tolerance.
Mutation evidence 6/6 killed, with GATE 3 declared NON-DISCRIMINATING: it reads
`data.d`/`data.t`, i.e. the fixture, so it cannot fail under any code mutation.

**Stage 1b blocker, recorded so it is not rediscovered.** The four nuisances now
exist; what remains is that upstream's `nu2` needs `m_alpha`/`rr` across four
upstream branches, one of which is unreachable because `DoubleMLDIDCS::new` has
no `score` parameter while the sub-DID hardcodes `score="observational"`.
Upstream's did_cs numbers are therefore an architectural change to the
estimator, not a formula swap; until stage 2 lands, `nu2` is still
`mean(psi_a^2)` on the DML score element and NOT upstream's
`mean(2*m_alpha - rr^2)`.

**did_cs sensitivity, stage 1 of 4** -- v0.146.0 adds
`DoubleMLDIDCS::predictions_m()`, the cross-fitted group propensity
`m_hat = E[D | X]` on the LONG panel, plus `sensitivity_folds()` exposing the
panel-wide folds behind it. Upstream's did_cs decomposition needs exactly this
(`did_cs.py:470`, `propensity_weight_d0 = m_hat / (1 - m_hat)`), and the port
could not produce it for two independent reasons: each `(g, t)` cell delegates
to a child `DoubleMLDIDBinary` restricted to that cell's two cohorts and two
periods, so its propensity is a different object; and `DoubleMLDIDCS` exposed
no prediction accessor at all. Strata mirror upstream's `d + 2*t`.

**Purely additive -- no reported number moves**, and that is asserted rather
than asserted-to: GATE 5 of `expand_v146_test.mbt` pins three `coef`/`se` pairs
against values recorded before this change existed. Its first draft pinned them
bit-for-bit and failed on three of four backends -- chasing that showed the
did_cs estimates differ by about 1.5e-15 relative across backends, which is
pre-existing and unrelated to this additive change. The gate now uses a 1e-12
relative tolerance drawn from that measurement, while GATE 5b pins the NEW
nuisance exactly, since it has no inherited spread: `mean(m_hat) =
0.5627032315060088` on all four backends.

**Stage 1b blocker, recorded so it is not rediscovered.** Upstream's `sigma2`
needs `g_hat` from **four** `(d, t)` outcome nuisances (`did_cs.py:445-449`);
the port has **two**, split by `d` only, taken from each cell's child, and they
cannot be recovered -- only refit on the full panel. Separately,
`DoubleMLDIDCS::new` has no `score` parameter while the sub-DID hardcodes
`score="observational"`, so upstream's two `experimental` branches are
unreachable. Upstream's did_cs numbers are therefore an architectural change to
the estimator, not a formula swap; until stage 1b lands, `nu2` is still
`mean(psi_a^2)` on the DML score element and NOT upstream's
`mean(2*m_alpha - rr^2)`.

`DoubleMLLPLR`, `DoubleMLRDD` and friends have **no upstream sensitivity
implementation at all** — upstream sets `_sensitivity_implemented = True` for
only seven classes (`did`, `did_binary`, `did_cs`, `did_cs_binary`, `apo`,
`irm`, `plr`), LPQ's `_sensitivity_element_est` is a bare `pass`, and
`ssm`/`lplr`/`plpr` explicitly disable it. So the port's extra sensitivity
entry points are **extensions, not divergences**. Eighth, fixed in
**v0.131.0**: for the seven that *are* upstream-faithful, the shared `nu2` was
`mean(psi_a^2)` — which is upstream's *fallback* formula, used only when the
primary comes out non-positive (`double_ml.py:1634-1641`) — and it was applied
to `psi_a`, the score's base element, rather than to `rr`, the **Riesz
representer**, which upstream keeps deliberately separate. The primary is
`nu2 = mean(2*m_alpha - rr^2)` (`did_cs_binary.py:932`). Measured: `nu2`
3.3028 → 26.7189 (8.1×), `rv` 12.2969 → 4.3234. `psi_sigma2`/`psi_nu2` turn
out to be **dead** on this path — they feed only `psi_max_bias`, which every
caller discards — so the whole reported result is a function of `sigma2` and
`nu2` alone. `DoubleMLDIDCSBinary` was migrated to
`irm_style_sensitivity_from_elements`; `did`, `did_binary`, `did_cs`, `apo`,
`irm` still uses the old convention and needs its own `m_alpha`/`rr`
plumbing. `plr` could not be migrated that way at all, and is resolved
separately in **v0.144.0**: its `nu2` is not a mean of a per-observation
element but the **scalar** `1 / mean((d - m_hat)^2)` (`plr.py:290-293`). The
port passed `psi_a = -v^2` into the shared helper, which squares its third
argument, so it reported `mean(v^4)` -- the **fourth** moment, a different
functional form rather than a differently-scaled version of the intended
quantity. Measured on a seeded confounded design (n = 500, seed 20261):
`mean(v^4) = 0.076516` against `1/mean(v^2) = 4.609163`, a factor of **60.24**
that moves with the data. `sigma2` was `mean((y - l_hat)^2)` rather than
upstream's `theta * v`-centred `mean((y - l_hat - theta*v)^2)` (`0.775939` vs
`0.336927`), so the "residual variance" still contained the coefficient's own
contribution. `rv` was therefore not the Cinelli-Hazlett robustness value.
Fixed IID and cluster, with six gates that recompute both formulas
independently. Upstream's per-observation `psi_nu2` has mean exactly zero by
construction, so transcribing it literally would route PLR through the
`nu2 <= 0` fallback and reach the right number by the branch reserved for a
degenerate case; the scalar is transcribed instead, and the new shared
`sensitivity_from_variance_baselines` is what licenses passing baselines
directly. `pliv` was added to the unsupported list in the same release --
upstream never sets `_sensitivity_implemented = True` for it either. Separately, upstream defaults
`in_sample_normalization` to `True` (`did_cs_binary.py:121`) and this port to
`false` (`did_cs_binary.mbt:732`) -- **uniformly across all six DID
estimators**, upstream being `True` in all five of its own. This is a
deliberate backward-compatibility choice, not a transcription slip: v0.8.0
picked `false` so the default stayed "byte-equal to the pre-0.8.0 port". Both
branches are implemented and were verified faithful in v0.131.0, so the formulas
agree; only the *default* differs. Measured on two independent staggered DGPs,
flipping it moves `coef` by 0.03%, `se` by 3-4% and sensitivity `nu2` by
0.6-1.2%, and leaves `sigma2` bit-identical (`sigma2` is unweighted upstream,
`did_cs_binary.py:867`). To match upstream exactly, pass
`in_sample_normalization=true` explicitly.
The config is also folded into the memoize key, not just its threshold,
so two estimators sharing a `clipping_threshold` but differing in
calibration are kept apart.

**Solver diagnostics** -- v0.145.0 gives `DoubleMLLPLR` a
`warnings()` accessor, the first diagnostic channel in the package. Until now
it had none by design (no `println`, no stderr: a numerical library that writes
to the console makes its own test output unreadable), and that same silence is
why `fit` could end its damped-Newton loop with `let _ = converged` and then
report a coefficient and standard error computed at a **non-solution** without
saying so. Warnings are **returned, never printed** -- the caller decides:

```moonbit
let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
for w in model.warnings() { println(w) }
```

The failure is easy to miss because it does not look like one. `se` is
`sqrt(gamma / (j^2 * n))` with `j = mean(psi_deriv)`, so leaving the root makes
the reported standard error *smaller*. On the package's own
`make_lplr_LZZ2020` (n = 800, seed 17):

| alpha | warns | `se` | `coef` |
|---|---|---|---|
| 0.25 / 0.50 / 0.75 | no | `0.285` / `0.465` / `1.507` | `0.703` / `1.204` / `2.351` |
| **1.00** | **yes** | `1.7e-06` | `-10.367` |
| 1.25 / 1.50 / 2.00 | yes | `2.6e-06` / `3.8e-06` / `2.1e-05` | `-10.001` / `-9.702` / `-8.370` |

The boundary lands at **alpha = 1.00**, reproducing the cliff v0.140.0 located
indirectly from the SE and CI -- the same edge, found from a different
observable. The reason is `exhausted_step_budget` and the reported `theta` is
about `-10.7`: the damped step is clamped to `0.25`, so 50 steps walk the
iterate ~12 units out and simply run out of budget. Three distinct exits are
named, since they are different faults: `degenerate_derivative`, `diverged`,
`exhausted_step_budget`. This is unrelated to the v0.144.0 sensitivity work --
one is about the sensitivity API surface, the other about an estimate.

**Known divergence, reported and NOT gated: the small-n regime.** At n = 500
the port and upstream agree to ~0.007. That is one design point, and it is
the one this estimator was never wrong at. On identical rows and the
identical outer partition, below it:

| n | port | upstream | port `se` | upstream `se` |
|---|---|---|---|---|
| 60 | `-0.049` | `3.53962` | `0.762` | `20.199` |
| 100 | `14.431` (warns) | `-0.558127` | `751657` | `0.832026` |
| 160 | `0.580578` | `0.749398` | `0.777` | `0.588` |

91 of 200 small-n designs still warn. **Upstream warns too** -- measured on
this DGP with real `DoubleMLLPLR` fits, 25 draws per n: at n = 60 upstream
emits a non-finite SE on 7 of 25 draws (`coef = nan, se = nan` twice,
`coef = 5.4e22, se = inf` once) and raises its own `Could not find a root of
the score function` warning on 11 of 25; at n = 100 and n = 160 it is 1 of 25
each; at n = 500 it is 0 of 25. The "upstream is 0/300 non-finite" figure that
used to justify the clamp is real, but it was measured at n = 500 only --
where nothing fails -- and was then read as a property of the estimator.

**Neither implementation is reliable below n ≈ 200, and they fail in opposite
directions.** Read the table above against its own rows: at n = 60 the port is
the well-conditioned one (`se` 0.76) and upstream is the pathological one
(`se` 20.2, `coef` 3.54 against a true effect near 0.5); at n = 100 it is
exactly reversed -- the port is the broken one (`se` 7.5e5, one warning) and
upstream returns `se` 0.83; at n = 160 both are finite and well-conditioned
and sit 29% apart. So the gap tabulated above is **not** uniformly "the port
returning a finite answer where upstream returns `nan`". On some rows that
description is backwards.

The honest summary is: upstream's small-n rate is genuinely bad (7 of 25
non-finite at n = 60), which is what justifies keeping the clamp rather than
adopting upstream's bare Newton; but the clamp is **not** the explanation for
the tabulated rows, and at n = 60 the port is the better-behaved of the two.
Telling them apart requires per-draw inspection, not an aggregate rate.

**What the cause actually is, and why it is not a port defect.** The port's own
`t_pred`, `m_pred`, `a_pred` and `beta` were dumped on the exact n = 66 rows
where the unclamped port dies, and handed to *upstream's own* solver. The
`t`/`m`/`a` values are harmless; `beta` alone reproduces the divergence, all 8
of 8 swap cells. And inside `beta`, it is not `r_hat = t - beta * a` that hurts
but the **Newton start value** `mean(beta)`, which upstream also uses verbatim
(`plm/lplr.py:326`, `np.average(beta)`).

Upstream never sets `_coef_bounds` for LPLR, so `double_ml_score_mixins.py:149`
runs `root_scalar(..., method="newton")` -- an **unbracketed** Newton from that
same start. This port is structurally identical; the clamp is standing in for a
robustness upstream does not have either. On the n = 66 rows the score is nearly
flat past `theta ≈ 3.5`: at `theta0 = 6.842` the derivative is `-8.07e-05`
against a score of `-0.1119`, a factor of **344** down, so the first step
`theta - score/deriv` overshoots to about `-1381` and overflows. That is the
`e+70` / `e+122` / `NaN` mechanism, and the basin edge is draw-specific.

The decisive number, on 40 **pinned** redraws of those same rows, with nothing
instrumented -- upstream's own `DoubleMLLPLR(...).fit()`, reading `.coef[0]`:
**17 of 40 (42%) return a non-finite or absurd coefficient** (`-648`, `5.18e+70`,
`8.44e+122`, `172149`, `nan` × 4, …), raising upstream's own `Could not find a
root of the score function` warning on 18 of 40. Upstream's `mean(beta)` over
those draws has mean 2.56, sd 3.39, range `[-3.21, 13.85]`, and this port's
`6.842` sits at the **90th percentile** -- an unremarkable draw, not a port bias.

So the clamp is not rescuing a defect this port introduced. It is covering a
fragility upstream shares and does not guard against either, and on this row set
it is what makes the port *no worse* rather than better. Record:
`_verify/LPLR_GATE_BLINDNESS_1680.md` sections 25g-25h and 27.

This is **reported by `pyexample_lplr.py` section 5 on every run and asserted
by nothing**, on purpose: a gate that is red forever gets ignored, which is
worse than no gate. The cause sits in the Newton step. The port damps it
(`lplr.mbt`, clamped to 0.25) and upstream does not -- scipy's Newton is a
bare `p = p0 - fval/fder`. Removing the damping *is* the faithful port, and it
was measured A/B at `8c01e96` by raising the two damping thresholds so the
branch cannot fire, then reverting:

| n | clamped | unclamped | upstream | gap, clamped -> unclamped |
|---|---|---|---|---|
| 60 | `-0.0491291` | `-0.0491291` | `3.53962` | `3.589` -> `3.589` (**no change**) |
| 100 | `14.431` (warns) | `-0.643589` | `-0.558127` | `14.989` -> **`0.085`** |
| 160 | `0.580578` | `0.580578` | `0.749398` | `0.169` -> `0.169` (**no change**) |

So the clamp costs **nothing at n=60 and n=160** -- it is bit-identical to the
unclamped arm on both. It bites at n=100 alone, where it is the whole
difference between agreeing with upstream to `0.085` and being `14.989` away.

It is not shipped, because the same A/B reproduces the failure that justifies
it: unclamped reaches `se = NaN` at `theta = -440.16` by trial 2 of
`examples/fuzz` and aborts on `var_est.mbt:79`, while upstream's own unclamped
answer at those sample sizes is non-finite on 28% of draws. **The two
requirements pull in opposite directions** -- the one design where upstream
has a clean answer is not the one where this port can safely drop its damping.
That tension is the honest state of this estimator below n ~ 200, and it is
why no single change fixes both rows.

Four candidates are now measured and none is the whole story. The `d_tilde`
nuisance: falsified. The `a_hat` double cross-fit as `m_pred`: falsified.
The Newton stopping tolerance: a real 14.8x difference against scipy's
`1.48e-8`, never exercised -- 0 of 600 solves enter the window where the two
disagree. And `a_hat["preds"]` itself, which the port does **not** reproduce:
upstream averages every inner model's prediction and the port uses a single
outer OOF. **That last one is real but measured at 1.7% of `a_hat`'s own span,
and it is not a cause.** Holding everything else at upstream's values it shifts
the coefficient by `+3.9e-4` against the gate's own band floor of `1.3e-1`,
Newton survival ties at every `n` tested (18/18, 20/20, 25/25, 25/25 of 25 at
`n = 60 / 100 / 160 / 500`), and the `mean(psi)` and first-step ratios are
`0.99` to `1.02`. Matching upstream here would move nothing, so it is **not
implemented**.

> An earlier revision of this file reported that candidate as "69% of `a_hat`'s
> span", leaving `mean(psi)` "~13x larger", the first Newton step "~1400x
> larger", and surviving "strictly more often (16 vs 15, 21 vs 19, 20 vs 19 of
> 25)". **All four numbers were wrong and are withdrawn.** They came from a
> Python stand-in for the port that used sklearn's `.predict` -- hard 0/1
> labels -- where upstream uses `predict_proba`. The port is on the
> probability side (`logistic.mbt:217` returns `sigmoid(eta)`; the labels are
> a separate `predict_class`). The measurement was of labels against
> probabilities, not of bagging against a plain cross-fit.

Every other element is verified equivalent term by term. The record, including
three corrections of claims this file previously carried, is in
`_verify/LPLR_GATE_BLINDNESS_1680.md` sections 13-22.

**Robust variance & inference** -- heteroskedasticity-consistent (HC)
standard errors, cluster-robust variance, multiplier bootstrap
confidence intervals, joint CIs, and Romano-Wolf multiple-testing
p-value adjustment. Reused via the `bootstrap.mbt` helper extracted
in v0.55.0.

**Huber-White sandwich API (v0.79.0+, expanded through v0.89.0)** --
`sandwich.mbt` provides the `sandwich_variance_hc0` / `_hc1` /
`_hc2` / `_hc3` free functions, `cluster_sandwich_variance`, and
`bias_corrected_theta`, all driven by the `SandwichKind` enum. From
v0.86.0 they are reachable through ONE shared
`sandwich_variance(kind, psi_a, psi, m_inv, n_obs, n_params)`
dispatch, and **15 of the 22** `DoubleML*` estimators expose the
estimator-level triple `sandwich_se(kind)` /
`cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`:
`DoubleMLIRM`, `DoubleMLPLR`, `DoubleMLIIVM`, `DoubleMLPLIV`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,
`DoubleMLDIDCSBinary`, `DoubleMLCVAR`, `DoubleMLSSM`,
`DoubleMLAPO`, `DoubleMLPLPR`, `DoubleMLPQ`, `DoubleMLLPQ`,
`DoubleMLLPLR`. (Re-measured: the quantile trio was missing from this
list while the Status table already counted all 15, so the two
disagreed inside one file.) (`DoubleMLRDD` and `DoubleMLBLP`
already emit HC0 intervals by calling
`LinearRegression::sandwich_se` internally.)

> **`DoubleMLBLP::confint_joint` ignored `level` -- fixed in v0.159.0.** It
> hardcoded `let z = 1.959963984540054` (`blp_policy.mbt:746`) while `level` was
> accepted, range-checked at line 727, and then never used -- so `level=0.50`
> and `level=0.95` returned byte-identical intervals, which removes the entire
> point of the argument. Now level-aware, following the convention already used
> in this package (`did_cross_section.mbt:485`): the exact constant at
> `level == 0.95`, so the default stays bit-exact, and `norm_ppf` otherwise.
> The multiplier is `sqrt(chi2(1, level)) = z_{(1+level)/2}`, the same value
> `statsmodels.OLS.conf_int(joint=True)` applies. Because the interval is
> symmetric, the width is exactly `2 * z * se`, so **width ratios are
> data-independent** and can be pinned without hard-coding a fitted number:
>
> | level | width (n=400, contrast on (intercept, x)) |
> |---|---|
> | 0.50 | `0.03691929183204845` |
> | 0.95 | `0.10728184750635172` |
> | 0.99 | `0.1409923584966286` |
>
> `width(0.95)/width(0.50)` measured `2.9058479234757097` against
> `1.959963984540054 / norm_ppf(0.75)` = `2.905847923475711`, agreeing to
> `1.3e-15`. Note the numerator is the **hardcoded** 95% constant, not
> `norm_ppf(0.975)`: this package's `norm_ppf` returns `1.9599627869916687`
> there (accurate to ~6e-7 relative), which is exactly why the special case
> exists. Note the convention:
the per-observation score is `psi[i] = psi_at(coef, psi_a, psi_b)[i]`
= `coef * psi_a[i] + psi_b[i]` -- the estimating function
`f(theta) = E[theta * psi_a + psi_b]` that `var_est` inverts, whose
root is `theta_hat = -mean(psi_b) / mean(psi_a)` -- and
`M_inv = [[1 / mean(psi_a)]] = 1 / (d f / d theta)`. Only
`M_inv[0, 0]^2` enters the variance. The HC2 / HC3 leverage is the
constant mean-regression diagonal `h_ii = 1 / n_obs` (fixed in
v0.88.0), so `HC2 == HC1` and `HC3 == HC1^2 / HC0` and the ordering
is `HC1 == HC2 > HC0` and `HC3 > HC2` -- a monotonic widening.
See `expand_v090_test.mbt` for the score-order evidence and for the
still-open factor between `se()` and `sandwich_se(HC0)`.

**`DoubleMLRDD` is not in that list, and does not join it (v0.96.0).**
It has its own `hac_se(kind)` / `cluster_hac_se(cluster_ids)` /
`leverage()` / `n_local_params()`, and it is deliberately NOT named
`sandwich_se`, because the two HC0 formulas are different algebras.
RDD's is a kernel-weighted local-regression sandwich,
`sum_k w_k^2 * m_k^2 * e_k^2` with `m_k` the intercept row of a full
`p1 x p1` normal inverse and no `1 / n^2` divisor; the shared helper
is a scalar-Jacobian MEAN-moment sandwich,
`M_inv[0,0]^2 * sum_i psi[i]^2 / n^2`. Feeding RDD's influence function
`psi_a[k] * residuals[k]` into the pre-v0.91.0 accumulator
`sum (psi_a * psi)^2` yields `sum psi_a[k]^4 * e_k^2` -- a fourth
power against RDD's second -- and the resulting error is a plausible
`1e-2`, not an obvious one. RDD also has no DML moment, hence no
scalar `M_inv` to supply, and its HC2 / HC3 leverage is a real WLS hat
diagonal rather than the shared helper's constant `1 / n`, so
`HC2 == HC1` does not carry over. The anchor is
`hac_se(HC0) == se()` bit-identically on a `cov_type = "HC0"` fit; on
a `"homoskedastic"` fit it is deliberately not, and `hac_se` refuses a
non-OLS learner and a `fuzzy = true` fit rather than returning a
number under the wrong name. Sandwich coverage above is unchanged --
RDD is not sandwich coverage. See `CHANGELOG.md` [0.96.0] and
`expand_v096_test.mbt`.

**RDD's own robust variance is a different thing again (v0.110.0-v0.116.0).**
Neither `se()` nor `hac_se()` is `rdrobust`'s robust variance for the
bias-corrected estimator, and RDD has a whole family of its own:

- `optimal_bandwidth()` / `optimal_bias_bandwidth()` -- `rdrobust`'s
  `bwselect = "CCT"` MSE-optimal estimation bandwidth `h` and
  bias-correction bandwidth `b`. They are different numbers because a
  degree-`j` local polynomial's bias is `O(h^(j+1))`, so the point
  (`p = 1`) and bias (`q = 2`) criteria carry different variance
  exponents. Measured `b / h = 0.907`.
- `nn_residual(x, y, nnmatch?)` -- the fit-free nearest-neighbour matched
  residual, transliterated from upstream's `_nn_residuals_jit` including
  its mass-point block walk. Byte-identical to the oracle at four
  `nnmatch` values and on a mass-point fixture.
- `tau_bc()` -- the bias-corrected point estimate, procedure (ii) and
  (iii) alike.
- `tau_bc_se_rb(vce = "nn" | "hc0")` -- procedure (iii)'s standard
  error. Its meat matrix is `Q`, the p-order fit *minus* its estimated
  bias term, with the p-order Gram at `h` as bread even though the
  estimate is a q-order quantity at `b`.

These are opt-in and leave `coef()` / `se()` untouched. They are checked
against the upstream Python port of `rdrobust`, not against internal
identities -- see the oracle paragraph below. Sharp designs only: fuzzy
CCT delta-method terms are not ported.

**Coverage by class**:

- *Observational / quasi-experimental*: `DoubleMLDID`,
  `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
  `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`, `DoubleMLRDD`,
  `DoubleMLSSM`.
- *Strategy & distributional*: `DoubleMLAPO` / `DoubleMLAPOS`,
  `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLCVAR`,
  `DoubleMLBLP`, `DoubleMLPolicyTree`.

**Reproducible DGPs + Python reference validation** -- 24 Python
scripts (`validate_*_with_python.py`) drive the DGPs
(`plr_CCDDHNR`, `plr_turrell`, `plr_confounded`, `irm_discrete`,
`irm_heterogeneous`, `irm_confounded`, `iivm`, `pliv` /
`pliv_cluster`, `SSM`, `simple_rdd`, `DID SZ2020` / `CS2021`, etc.)
and check within-tolerance equivalence against the upstream Python
outputs. CI runs each script and requires **both** a zero exit code and a
trailing `PASS` line -- the second condition alone used to be the only one
checked, and it is trivially satisfied by a script that never ran MoonBit.

**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which can only catch a disagreement someone already
thought to look for. The `pyexample_*` scripts instead run upstream's own code
on the port's rows and compare that: not "does the port agree with our second
implementation" but "does the port agree with upstream". Measured designs, one
script per upstream class:

| script | upstream class | how the two sides get their rows |
|---|---|---|
| `pyexample_did.py` | `DoubleMLDID` on `make_did_SZ2020` | upstream's own DGP |
| `pyexample_did_cs2021.py` | `DoubleMLDIDMulti` on `make_did_CS2021` | upstream's own DGP |
| `pyexample_did_binary.py` | `DoubleMLDIDBinary` | shared rows |
| `pyexample_did_cs_binary.py` | `DoubleMLDIDCSBinary` | shared rows |
| `pyexample_lplr.py` | `DoubleMLLPLR` | shared rows + pinned outer partition |
| `pyexample_pq.py` | `DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ` | integer-only DGP, rebuilt independently on both sides |
| `pyexample_policytree.py` | `DoubleMLPolicyTree` | integer-only DGP; the **label vector over every row** is compared, because the port's builder and upstream's `DecisionTreeClassifier` differ in threshold convention, criterion and leaf rule |
| `pyexample_rdd.py` | `DoubleMLRDD` vs `rdrobust` | integer-only DGP **with genuine non-collinear noise**; the bias-corrected arm is gated |
| `pyexample_suite.py` | the core estimator family | mixed |

**`DoubleMLRDD`'s shipped default arm is still the one absence.** `coef()` / `se()` are
homoskedastic and **uncorrected**, so they are a *different estimator* from
`rdrobust`'s default rather than a worse implementation of the same one, and matching
them would be a re-specification rather than a bug fix. What `pyexample_rdd.py` gates is
the arm that does match: `tau_bc` against upstream's `tau.bc` (measured gap **6.2e-15**
absolute, **3.1e-15** relative) and `tau_bc_se_rb` against `se.rb` (**1.9e-15** absolute,
**1.4e-14** relative), both at relative bound `1e-11`. The default arm
is printed beside the gate on every run — `~5.9e-3` relative on the point estimate and
`0.053x` upstream's on the SE (`~19x` smaller) — so the divergence is visible rather
than asserted. The standing rule is
the same one below: a
recorded defect beats a gate that cannot pass. With RDD recorded and the other
four gated, every estimator slot on `examples/main` that once had an analytic
oracle only is now either gated against upstream or measured.

The multi-cohort half is the one worth reading the CHANGELOG for. It was
absent for a release cycle on a documented refusal whose two reasons were both
**false**: upstream does ship `DoubleMLDIDMulti`, and the never-treated
conventions do not disagree -- `_get_never_treated_value` returns `0` for
integer `g`, which is exactly this port's own rule, and the `inf` that broke
the earlier attempt came only from `time_type="float"`. Upstream's 12-cell
`"standard"` grid maps onto 6 cells the port can express, all of them
post-treatment cells of all cohorts, each gated at a **per-cell measured**
3-sd band (the coefficient's signal is 12-57x the fold noise, the standard
error's 1.8-4.4x — one band per cell serves both rows, and the weaker of the
two is the standard error). `DoubleMLDIDMulti`'s `ignore(t_pre)`
is a real divergence from upstream and is not fixed; it is unreachable on those
6 cells, which is what makes the comparison sound rather than lucky.

**An upstream ORACLE for RDD (v0.116.0)** -- the scripts above check
against hand-written reference outputs, which can only catch a
disagreement someone already thought to look for. RDD now also has a real
oracle: the **Python port of `rdrobust` shipped in the upstream
repository `rdpackages/rdrobust`**
(`Python/rdrobust/src/rdrobust/`), pinned under
`_verify/_upstream_rdrobust_py/` and runnable via `_verify/_oracle/`.
`_verify/gen_v116_oracle.py` calls it and writes
`_verify/_v116_golden.json`; every constant in
`moonbit_doubleML/expand_v116_test.mbt` comes from that file.

It earns its keep. The oracle found that v0.115.0's `tau_bc` -- which had
a green suite and two gates asserting a stated identity -- was not
`rdrobust`'s bias-corrected estimate whenever `b != h`. The v0.115.0 gate
had compared two internal routes to the same wrong number, so no
internal assertion could ever have caught it. `_verify/mut_v116_rdd.ps1`
records the equivalent.

**Docs & demos** -- 6 `doc/<NNN_...>/` tutorials targeting `wasm-gc`,
plus 19 `examples/<bin>/` driver binaries (all listed in
`moon.work`), of which `examples/api_server/` is an HTTP service
built directly on `moonbitlang/async@0.20.3` -- no third-party HTTP
framework is pulled in.

**Strict dependency hygiene** -- only official `moonbitlang/*` packages
in the library. Non-official deps restricted to `riantr/*` (this
repo). Reproducible builds, minimal supply-chain surface.

**Learner injection via `LearnerDispatch`** -- every estimator's
`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
optionals. Default is `LearnerDispatch::linear_regression()` (OLS).
Built-in learners:

| learner | kind | `sample_weight` | note |
|---|---|---|---|
| `LinearRegression` | regression | WLS | OLS, the default |
| `Ridge` | regression | weighted | **v0.120.0+**, L2 penalty, unpenalised intercept |
| `Lasso` | regression | weighted | **v0.120.0+**, L1 penalty, coordinate descent |
| `ElasticNet` | regression | weighted | **v0.120.0+**, the convex L1/L2 blend |
| `LogisticRegression` | **classification** | weighted IRLS | binary, IRLS Newton-Raphson |
| `RFClassifier` | **classification** | weighted | v0.117.0+, Breiman 2001, Gini splits |
| `GBClassifier` | **classification** | weighted Newton leaf | v0.117.0+, Friedman 2001, binary log loss |
| `RFLearner` | regression | weighted splits/leaf | Breiman 2001, MSE splits |
| `GBLearner` | regression | weighted leaf | Friedman 2001, squared-error loss |
| `ConstantLearner`, `NoopLearner` | either | ignored | constant / zero predictors |

Upstream `doubleml` is learner-agnostic -- `ml_g` / `ml_m` are any
object with `fit` / `predict` -- so it inherits scikit-learn's whole
learner surface. This package ships eleven. The four tree/logistic
learners' `predict` returns `P(y = 1 | x)` for classification, never a
hard label, because DML's AIPW correction divides by the fitted
propensity.

**The regularised learners penalise the slopes, not the intercept.**
All three centre the design, solve for the slopes, and recover the
intercept as `y_mean - x_mean . beta`; scikit-learn does the same.
Folding the intercept into `X` as a column of ones -- which is what
`LinearRegression` does -- and penalising it is a *different estimator*,
and the two intercepts differ by 2.7e-2 at `alpha = 0.7`.

**`alpha` means two different things across the two families.** `Ridge`
minimises `||y - Xw||^2 + alpha*||w||^2`; `Lasso` / `ElasticNet`
minimise `(1/2n)||y - Xw||^2 + alpha*(...)`. Equal numeric `alpha`
therefore shrinks far harder for Lasso. The identity that pins it:
`ElasticNet(l1_ratio = 0, alpha = a) == Ridge(alpha = a*sum(sample_weight))`
-- note `sum(sample_weight)`, which reduces to `n` unweighted.

**Learner surface is at parity with doubleml 0.11.4.** An earlier
version of this README listed "GLM families (Poisson, Gamma, negative
binomial)" as a gap. **That was wrong**, in the same way an earlier
release claimed a `ps_dm` the sdist does not contain: doubleml 0.11.4
has no `DoubleMLPoisson` / `DoubleMLGamma` / `DoubleMLNegativeBinomial`,
and no `PoissonRegressor` / `GammaRegressor` / `QuantileRegressor`
anywhere in it. `DoubleMLPQ` fits its outcome model as a *classifier on
the indicator `1{y <= theta}`* (`pq.py:253`, `pq.py:390`), which this
port already has. GLMs would be an extension beyond upstream, not a
parity gap.

`sample_weight` landed in v0.118.0 -- the trait
is `fit(x, y, sample_weight)` with an empty array meaning unweighted,
matching upstream's protocol and scikit-learn's `sample_weight=None`.

`RFLearner`, `GBLearner`, `RFClassifier` and `GBClassifier` reach the 5
specialised internals -- `DoubleMLDIDCrossSection::crossfit_nuisance`,
`DoubleMLDIDCSBinary::cs_bin_crossfit_nuisance`,
`DoubleMLPQ::solve_pq` / `DoubleMLQTE::solve_pq`,
`DoubleMLCVAR::cvar_inner_crossfit`, and
`DoubleMLLPLR::cross_fit_predict_dispatch` (binary classifier slots) /
`DoubleMLRDD::rdd_side` (kernel-weighted OLS for `ml_g = LinearRegression`,
unweighted fallback for other learners). Defaults preserve v0.61.0
byte-equality; non-default overrides change the IF and the coef.

##Quick Start

Run these from the **repository root** -- the directory holding `moon.work`.
`moon test --target native` prints the same total from either directory, but
`moon run examples/main` and `python validate_irm_with_python.py` are
repo-root paths and fail from inside `moonbit_doubleML/`.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.

$ moon run examples/main
=== MoonBit DML PLR (partialling out) ===
true theta_0      = 1
estimated theta   = 1.092018247331361
standard error    = 0.08875683254582736
...

$ python validate_irm_with_python.py
======================================================================
PASS  |mb - handrolled_nrep5| (theta) = 8.868664e-02 < max(MODEL_TOL=0.1, 2.0*handrolled_n5_se) = 1.912555e-01
```

`--target native` is spelled out because the package's `preferred_target` is
`wasm-gc`, where the suite is **1123** -- 1117 plus 6 doc tutorials; the
per-target numbers are in the Status table. A bare `moon test` runs every
declared backend, and on `moon 0.1.20261016` it prints `Total tests: 0` for
the backends other than the preferred one, so the per-target counts here
come from explicit `--target` runs.

##Library Use

```moonbit nocheck
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]
let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
let coef = fitted.coef()      // Double
let se   = fitted.se()        // Double
let (lo, hi) = fitted.confint()
```

Same shape for every other estimator -- e.g.
`@moonbit_doubleML.DoubleMLIRM::new(data, ml_g?, ml_m?, n_folds?, n_rep?, seed?).
fit()`, `@moonbit_doubleML.DoubleMLDID::new(data, ml_g?, ml_m?, ...).fit()`.

##Examples

21 `examples/<bin>/` directories in `moon.work`. 16 are CLI-style numeric
demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **12** of the 16 print a 95 % CI -- `examples/pava` and
`examples/splitting` print neither, and `examples/apos`, `examples/cluster`
and `examples/ssm` print a true value but no CI. `examples/api_server/`
is an HTTP service; `examples/consumer_demo/` is the library-user pattern
that mirrors what an external `moon add riantr/moonbit_doubleML` consumer
would write; `examples/fuzz/` is the property-based fuzz harness; and
`examples/bitexact/` and `examples/parity/` are the MoonBit fixtures the
bit-exact and LPLR parity validators drive, kept as runnable binaries so
their numbers are inspectable without a Python reference.

`examples/apo/` and `examples/apos/` are the pair worth reading together:
APO returns the potential outcome AT one treatment level, APOS returns
those levels plus pairwise CONTRASTS, and a contrast is off by the
reference level's entire outcome. `examples/apo/` prints both so the gap
is visible rather than described.

| Driver | Model | DGP | True theta |
|--------|-------|-----|--------|
| `examples/main` | `DoubleMLPLR` + 11 others (IRM / PLIV / IIVM / DID / SSM / BLP / RDD / PQ / QTE / LPQ / PolicyTree) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `examples/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=4000`, 9 controls | 1.5 |
| `examples/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts x 4 periods | 1.0 |
| `examples/did_cs_binary` | `DoubleMLDIDCSBinary` | Staggered CS-DID with binary outcome | 1.0 |
| `examples/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |
| `examples/did_cross_section` | `DoubleMLDIDCrossSection` | Sant'Anna-Zhao 2020 cross-section DID, 500 units | 1.0 |
| `examples/plpr` | `DoubleMLPLPR` | Static-panel PLR (60 units x 4 periods) | 1.0 |
| `examples/lplr` | `DoubleMLLPLR` | Partially logistic regression, LZZ2020 | 0.5 (logit-scale `alpha`) |
| `examples/apo` | `DoubleMLAPO` | 3-level discrete treatment (`D` in 0/1/2): the LEVEL `E[Y(t)]` | 1.0 (`E[Y(1)]`) / 2.5 (`E[Y(2)]`) |
| `examples/apos` | `DoubleMLAPOS` | 2-level discrete treatment: per-level `E[Y(t)]` PLUS pairwise CONTRASTS | 1.0 per level; contrast 0.0 |
| `examples/cvar` | `DoubleMLCVAR` | CVaR at `q=0.5` | 1.74 |
| `examples/ssm` | `DoubleMLSSM` | Sharp synthetic treatment | 1.0 |
| `examples/cluster` | `DoubleMLPLIV` / `DoubleMLPLR` + `cluster_*` | Clustered data, cluster-robust SEs | 1.0 |
| `examples/splitting` | `DoubleMLPLR` + `set_sample_splitting` | External sample splitting (n=200, p=2) | 1.5 |
| `examples/pava` | `pava` core | Isotonic regression, exact (no MC error) | n/a -- fixed input cases, not a theta demo |
| `examples/fuzz` | wrappers | Random-property fuzz harness across 11 surfaces (native-only) | n/a |
| `examples/bitexact` | fixture | The bit-exact values and RNG keys `validate_bitexact_with_python.py` drives | n/a |
| `examples/parity` | fixture | The LPLR nuisance-space / instrument values the parity gate drives | n/a |
| `examples/consumer_demo` | library-user pattern | Minimal end-to-end PLR (no estimator-specific extras) | 1.0 |
| `examples/api_server` | `DoubleMLPLR` + `DoubleMLIRM` | HTTP service -- see below | n/a |

CLI demos (all 16 run bare; most print an estimate against a true value):

```console
$ moon run examples/main
$ moon run examples/datasets
$ moon run examples/did_binary
$ moon run examples/did_cs
$ moon run examples/did_multi
$ moon run examples/did_cross_section
```

HTTP service:

```console
$ moon build --target native examples/api_server
$ _build/native/debug/build/example/api_server/api_server.exe   # listens on 127.0.0.1:4000

$ curl -s http://127.0.0.1:4000/healthz
{"status":"ok"}

$ curl -s -X POST http://127.0.0.1:4000/fit/plr \
    -H 'Content-Type: application/json' \
    -d '{"x":[[1.0,0.5],[2.0,1.5],[3.0,2.5],[4.0,3.5],[5.0,4.5],[6.0,5.5]],"y":[2.0,4.0,6.0,8.0,10.0,12.0],"d":[1.0,2.0,3.0,4.0,5.0,6.0],"n_folds":2,"seed":3141}'
{"estimator":"plr","coef":2,"se":0,"ci_lo":2,"ci_hi":2,"n_obs":6,"n_features":2}
```

The same `api_server.wasm` also runs under `moonrun --port 4000`
(see `examples/api_server/README.md` for the full curl recipe).
The service is built directly on `moonbitlang/async@0.20.3` --
no third-party HTTP framework is pulled in.

##Models

22 estimators (`DoubleML*` structs) in 19 production files -- 16 with
one struct each, and three holding two (`apo.mbt`: `DoubleMLAPO` +
`DoubleMLAPOS`; `blp_policy.mbt`: `DoubleMLBLP` +
`DoubleMLPolicyTree`; `quantile.mbt`: `DoubleMLPQ` + `DoubleMLQTE`) --
out of 220 `.mbt` files in the package (65 production, 129 blackbox
test, 26 whitebox test). All are reachable through the same
`DoubleMLXxx::new(...).fit()` interface. 19 are marked *(upstream)*
against a name-identical `doubleml-for-py` class; two are marked
*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and
`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and one,
`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)* -- the
port's variant of upstream's `DoubleMLDIDMulti`:

| Model | Score | Description |
|-------|-------|-------------|
| `DoubleMLPLR` | partialling-out | partially linear regression *(upstream)* |
| `DoubleMLIRM` | ATE | interactive regression model *(upstream)* |
| `DoubleMLPLIV` | partialling-out | partially linear IV regression *(upstream)* |
| `DoubleMLIIVM` | LATE | interactive IV model *(upstream)* |
| `DoubleMLDID` | observational | difference-in-differences *(upstream)* |
| `DoubleMLDIDBinary` | observational | DID with binary outcome *(upstream)* |
| `DoubleMLDIDCS` | observational | DID with staggered adoption (Callaway-Sant'Anna) *(upstream design, no 1:1 class)* -- the port's variant of upstream `DoubleMLDIDMulti`, without its `gt_combinations` selector |
| `DoubleMLDIDCSBinary` | observational | CS-DID with binary outcome *(upstream)* |
| `DoubleMLDIDMulti` | observational | multi-period DID with group-time ATT aggregation *(upstream)* |
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(upstream, renamed)* -- upstream `DoubleMLDIDCS` |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) *(upstream)* |
| `DoubleMLAPO` | policy score | average potential outcomes for one treatment level *(upstream)* |
| `DoubleMLAPOS` | policy score | average potential outcomes across several treatment levels *(upstream)* |
| `DoubleMLPQ` | quantile | potential quantile *(upstream)* |
| `DoubleMLQTE` | quantile | quantile treatment effect *(upstream)* |
| `DoubleMLLPQ` | local polynomial | local potential quantile *(upstream)* |
| `DoubleMLLPLR` | partialling-out | partially logistic regression, Liu-Zhang-Zhou 2021 *(upstream)* |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | local polynomial | regression discontinuity *(upstream, renamed)* -- upstream `RDFlex` |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(upstream)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)*, + v0.98.0 honest split (`honest = true`) with `leaf_se` / `policy_value_se` |

The **Score** column is a prose label for the estimand family, not a
machine string, and three vocabularies are in play: the port accepts
its own lower-case spellings (`partialling-out`, `apo`, `pq`, `lpq`,
`cvar`, `policy_tree`, `nuisance_space`, `observational`); upstream
`doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`, `CVaR`,
`nuisance_space`, `partialling out`, `observational` and
`missing-at-random`, and takes **no score argument at all** for
`RDFlex`, `DoubleMLBLP` or `DoubleMLPolicyTree`. The
`doc/004_estimators` tutorial lists the port's own strings, one row
per estimator.

**Provenance (v0.103.0, re-measured).** The counterpart modules in
`doubleml` 0.11.4 are `plm/{plr,pliv,lplr,plpr}.py`,
`irm/{irm,iivm,apo,apos,pq,qte,lpq,cvar,ssm}.py`,
`did/{did,did_binary,did_cs,did_cs_binary,did_multi}.py`, `rdd/rdd.py`
(the class there is `RDFlex`), and `utils/{blp,policytree}.py` --
verified against the published sdist, not the GitHub tree, so this is
the shipped artefact. **Not** all 22 have a counterpart: see the
measurement below.

Provenance was re-measured against the **0.11.4 sdist** itself
(388 members, 322 of them `.py`) rather than read off a table, and
re-anchored to the **installed 0.11.3 package** -- the sdist itself is
not committed, being a vendored upstream artefact; it is at
`https://pypi.org/pypi/doubleml/json` -> `urls[sdist]`. Result: **19**
rows have a name-identical `class DoubleMLXxx` upstream, **2** are
upstream estimators under a different name -- `DoubleMLRDD` is
upstream's `RDFlex` and `DoubleMLDIDCrossSection` is upstream's
`DoubleMLDIDCS` -- and **1**, `DoubleMLDIDCS`, has no 1:1 upstream
class.

> **CORRECTED 2026-10-20.** This paragraph previously said **20**
> name-identical rows, and that `DoubleMLDIDCrossSection` had **no upstream
> estimator** -- marked `*(no upstream counterpart)*`. Both were wrong, and
> the scan behind them could not have found the answer: it looked for the
> *name* `DoubleMLDIDCrossSection` (0 hits over the sdist's 322 `.py`
> members), which shows there is no upstream class **by that name** -- not
> that no upstream estimator implements the same design.
>
> Upstream's `DoubleMLDIDCS` (`did/did_cs.py:17`) is *"Double machine
> learning for difference-in-difference with **repeated cross-sections**"*,
> takes a `DoubleMLDIDData` (one observation per unit, binary post-period
> indicator `t`), and fits the same 4 g-functions over `(d, t) ∈ {0,1}²` plus
> one propensity that this port's `DoubleMLDIDCrossSection` fits. This
> repository had known it all along: `validate_did_cross_section_with_python.py`
> mirrors `doubleml.DoubleMLDIDCS._score_elements` to produce the port's
> reference estimate. The port's `DoubleMLDIDCS` is the **panel**, group-time
> ATT estimator, and **upstream's `DoubleMLDIDMulti`** (`did/did_multi.py:46`,
> takes a `DoubleMLPanelData`, emits per-`(cohort, pre, eval)` ATTs) is its
> counterpart -- the tell is that `control_group` and `anticipation_periods`
> exist on upstream's `DoubleMLDIDMulti` and on **neither** upstream's
> `DoubleMLDIDCS` nor its `DoubleMLDID`, and the port's `DoubleMLDIDCS` has
> both.
>
> The design *is* known upstream and the DGP ships there -- upstream's
> `make_did_SZ2020` is *"Generates data from a difference-in-differences
> model used in Sant'Anna and Zhao (2020)"*. What was wrong was the
> conclusion drawn from it. The same crossed pair had already produced a
> **wrong headline measurement** in `_verify/IN_SAMPLE_NORMALIZATION_1570.md`
> §5, which compared the port's panel `DoubleMLDIDCS` against upstream's
> cross-section `DoubleMLDIDCS` and called the result a 20× sensitivity gap;
> that section is withdrawn there.
>
> **AMENDED 2026-10-20 (round 16).** The correction above fixed the *20 ->
> 19* count and the "no upstream counterpart" label, but its **pairing** was
> still wrong, and the `control_group` / `anticipation_periods` "tell" it
> relied on is not a tell. Upstream's `DoubleMLDIDMulti` has **both** of
> those parameters, so they identify the *family* -- multi-period panel DiD --
> and not one estimator inside it. The note therefore gave one upstream class
> **two** counterparts: it paired the port's `DoubleMLDIDCS` with upstream's
> `DoubleMLDIDMulti` while the table below also marked the port's
> `DoubleMLDIDMulti` as name-identical to upstream's `DoubleMLDIDMulti`. A
> 1:1 map cannot express that, and the label was not checkable.
>
> The decisive test is a **distinguishing parameter**, not a family
> signature. `gt_combinations` exists on **upstream's `DoubleMLDIDMulti`
> and no other upstream DID class** (`did/did_multi.py:65-68`), with the
> keywords `'standard'`, `'all'`, `'universal'`
> (`did/utils/_did_utils.py:127`) and results labelled `ATT(g, t_pre,
> t_eval)` (`did/did_multi.py:197`). On the port side, `gt_combinations`
> exists on **the port's `DoubleMLDIDMulti` and no other port DID
> estimator**. So upstream's `DoubleMLDIDMulti` is the port's
> `DoubleMLDIDMulti`, 1:1. The port's `DoubleMLDIDCS` has no
> `gt_combinations` at all: it derives its own `(g, t)` grid, fits a
> `DoubleMLDIDBinary` per cell, and transcribes upstream's `did_cs.py`
> machinery (lines 110, 445, 451, 456, 462, 464, 466, 470, 527, 529 --
> the 2x2 `(d, t)` nuisances and the panel-level sensitivity elements).
> Upstream's single multi-period class is therefore **split** across two
> port estimators, and the port's `DoubleMLDIDCS` is a **port-side
> variant** of it rather than a 1:1 counterpart. The grouping is
> corrected to **19 name-identical + 2 renamed + 1 with no 1:1 upstream
> class**; the derivation is `_verify/_audit_r16_provenance_1650.py` and
> the record is `_verify/UPSTREAM_PROVENANCE.md` (which, until this
> commit, was **not tracked at all**).

Three rows were previously marked *(extra)* -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR`. That was wrong: all three ship
upstream, so they had a reference implementation all along and
simply were not being compared against it. `DoubleMLDIDCSBinary`,
`DoubleMLDIDBinary` and `DoubleMLDIDMulti` are additionally absent from
upstream's `__all__` while still being importable from their modules.

### Honest policy trees (v0.98.0)

`DoubleMLPolicyTree::new(x, orth_signal, depth = 1, honest = false,
split_seed = 2024, min_leaf_n = 5)` splits the sample when `honest` is on:
`policy_tree_build` sees only
the splitting half, and every reported leaf statistic (`leaf_assignment`,
`leaf_signal_mean`, `leaf_count`, `leaf_se`) is computed on the
estimation half. That is the honesty of Athey & Imbens (2016, PNAS
113(27):7353-7358), and it makes their property a property rather
than a claim: with the partition held fixed, a leaf value is a plain
sample mean, so `leaf_se[k] = sd(y_k) / sqrt(n_k)` has its usual
sampling interpretation. `is_honest()` reports which regime produced a
number, and `honest` defaults to `false` so existing callers are
byte-identical.

Two caveats are load-bearing and are documented in-source. Honesty
fixes the *bias*, not the small-leaf variance: Cattaneo, Klusowski &
Yu (arXiv:2509.11381) show that CART-type greedy splitting picks
highly imbalanced splits with nonvanishing probability and that
"sample splitting ... does not remove this limitation", which is why
`min_leaf_n` (default 5) guards on estimation-half leaf counts and
`unreliable_leaves()` names the offenders instead of reporting an
untrustworthy `leaf_se` silently. And a single honest tree spends
about half the sample on each of its two jobs -- Wager & Athey
(2018, JASA) recover that precision by averaging many honest trees,
which this package deliberately does not attempt.

`policy_value_se()` is the EXACT standard error of the plain sample
mean, **not** the tempting `sum_k (n_k/n)^2 se_k^2`: that form
assumes independent leaf means, but group means of one sample are
negatively correlated, and the independence form collapses to exactly
zero when all the variation is between leaves.

##Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.164.11, 220 .mbt files)
  moonbit_doubleML.mbt   <- main re-export file (the import surface)
  ...                    <- one file per estimator + DGPs + score / nuisance kernels
  vectorized.mbt         <- v0.81.0+ vectorised cross-fit helpers

doc/                     <- wasm-gc-targeted numbered tutorials
  001_introduction/
  ...
  006_python_check/

examples/                <- 21 driver binaries (all listed in moon.work)
  main/                  <- 12 estimators in 18 runs: 5 also run with
                            n_rep=5, and RDD runs twice (sharp, fuzzy)
  datasets/              <- 401(k)-style ATE / ATT recovery
  did_binary/            <- 2-period panel DID
  did_cs/                <- staggered CS-DID
  did_cs_binary/         <- staggered CS-DID (binary outcome)
  did_multi/             <- multi-period DID aggregation
  did_cross_section/     <- Sant'Anna-Zhao 2020
  plpr/, lplr/, apos/,   <- single-estimator focused demos
  cvar/, fuzz/
  consumer_demo/         <- library-user pattern (`example/consumer_demo`)
  api_server/            <- HTTP service built on `moonbitlang/async`

moon.work                <- 23-member workspace aggregator (the library, doc/, 21 examples)
AGENTS.md                <- this file (per moonbit agent convention)
skills/moonbit_doubleML.md  <- agent skill: API surface + anti-patterns
```

##Dependency rule (per `skills/moonbit_doubleML.md`)

- Only official `moonbitlang/*` packages.
- Non-official packages may only be `riantr/*` (this repo).
- Pin to the latest published version (e.g. `moonbitlang/async@0.22.5`).
- Consequence: `examples/api_server/` builds directly on
  `moonbitlang/async`'s raw `Server` API. No third-party HTTP
  framework is allowed.

**Current state: the rule is not met, by one line.** `moonbit_doubleML/moon.mod`
declares two packages, and **neither is imported by any `.mbt` in the library**
(measured: 0 references each):

| declared | imported by the library? | note |
|---|---|---|
| `moonbitlang/async@0.22.5` | no | referenced by nothing: `examples/api_server/` uses the same package, but at its own pin -- `moonbitlang/async@0.20.3` -- so this line matches no import |
| `moonbit-community/sqlite3@0.2.3` | no | **not `moonbitlang/*`** -- added in v0.85.0 for `DoubleMLPolicyTree` memoisation, which now uses an in-memory `FitCache` |

So the library has no runtime third-party dependency today, while `moon.mod`
carries two dead entries -- one of which does not satisfy the rule above.
Deleting both lines is the change that would make this section true.

##Determinism & validation

### What CI actually gates

Measured from `.github/workflows/` and confirmed against the run list. Nine
gates, **seven of which run on push to `master`**; **eight of the nine also run
again before publishing**, and the one that does not is stated here rather
than left for a reader to assume. The two that run **only** before publishing
-- `moon check --deny-warn` and the generated-interface drift check -- are
marked **publish-only** in the table instead of being folded into the count:

| Gate | Where | Scope |
|---|---|---|
| Shipped README == edited README | `check.yml` `readme-sync` | `moonbit_doubleML/README.mbt.md` byte-identity |
| `moon build` + `moon test --deny-warn` | `check.yml` x4 matrix | `native`, `wasm-gc`, `wasm`, `js` |
| `moon fmt --check` | `check.yml` "Format check" x4, `publish.yml` | see caveat below |
| `moon check --deny-warn` x4 | `publish.yml` -- **publish-only** | warnings are errors; a push to `master` never runs this command |
| Generated-interface drift | `publish.yml` -- **publish-only** | public surface; `moon info` + `git diff --exit-code` run nowhere else |
| `typos` (pinned 1.19.0) | `publish.yml`, and `check.yml` via the QA LOOP's `static_code_check` | prose |
| 24 `validate_*_with_python.py` | `check.yml` | estimator parity; see the two-tier note below |
| 9 `pyexample_*` upstream gates | `check.yml` `python-cross-check` | the port against **upstream's own code**; see the table below |
| QA LOOP (fast scope) | `check.yml` `qa-loop`, `publish.yml` | 31 registered checks, 22 of them fast; CI also runs `api_test` and `security_dast` from the full scope |

Seven is not a rounding of the table -- it is the job count. The `CI` run on
`master` is **7 jobs**: `README sync`, `moon test --deny-warn` x4, `Python
cross-check`, and `QA loop`. `moon check` and `moon info` appear in none of
them. `typos` is the one row whose *Where* is easy to misread: it is a
`publish.yml` step, but it also runs on every push inside the QA LOOP's
`static_code_check`, with the same pinned `v1.19.0`, because that check is
`fast` scope.

`publish.yml` fires on a `v*` tag push, has a single job, and declares **no
`needs:`** -- it neither waits on nor depends on a `check.yml` run. It re-runs
the README check, the 4-backend check and test, the format check, the
interface-drift check, `typos`, the 9 `pyexample_*` gates (through the QA
loop's fast scope), the QA loop itself and the harness's own self-test. It
does **not** re-run the 24 `validate_*_with_python.py` scripts: that gate is
`check.yml` only. A tag push is therefore a *narrower* gate than a master
push, and the 24-validator parity check has to have passed on the commit
being tagged.

The other half of the asymmetry points the other way, and it is the half that
is easy to miss: **`moon check --deny-warn` and the interface-drift check run
only before publishing.** A push to `master` compiles and tests the package on
four backends but never runs the SAST-class pass and never diffs the
generated interface, so an interface change can sit on `master` unflagged
until the next release. Neither `publish.yml` nor `check.yml` passes `--full`
to the QA LOOP either, so the harness's `full` scope is not a release-time
scope; the two-tier note below says exactly what that leaves uncovered.

`nightly.yml` additionally runs the package against the MoonBit **nightly**
toolchain, so a breaking upstream change surfaces before it reaches stable.

**Two of these are weaker than the table makes them look, and both are stated
here rather than left for a reader to assume.**

- **`moon fmt --check` can fail, but it fails as a toolchain error rather than
  as a formatting report.** Measured on `moon 0.1.20261016`: a clean copy of
  `examples/main` exits **0**, and the same copy with one deliberately
  mis-formatted function exits **non-zero** (`4294967295`, i.e. `-1`, on
  Windows) and names `main.mbt` -- so the gate does discriminate. An earlier
  "it has not been shown to be able to fail" verdict was an artifact of a
  control arm that pointed the tool at a directory with no package in it, so
  the tool had nothing to look at; the QA harness's own control arm says so
  in `.github/scripts/qa_loop/checks.py`. The way it goes red is the
  remaining problem: the formatted copy under `_build/.../format/` is never
  written, so what actually fails is the follow-up `git diff --no-index`, and
  CI shows a toolchain error instead of "this file needs formatting". CI also
  installs the *latest* `moon` from `cli.moonbitlang.com` rather than a
  pinned version, and its run log is not readable without authentication, so
  its behaviour there is unverified.
- **`validate_splitting_contract.py` is not in the `python-cross-check` job.**
  It is tracked, but does not match that job's `validate_*_with_python.py`
  glob, so no cross-check step executes it. It does still run, as the QA
  LOOP's `contract` check -- `fast` scope, so on every push and before
  publishing. Measured today: exit 0, `Sample-splitting cross-check: PASS`,
  with all 6 invalid partitions refused.

**All 24 now spawn a MoonBit process, but they are not all the same kind of
check, and saying "24 / 24 PASS" without saying that would overstate what
passed.**

- **All 24 spawn MoonBit and compare its output**, over **248 comparison rows**
  across the ten that were rewritten. `validate_quantile_with_python.py` used to
  print `reference checks PASS` having never run MoonBit; `validate_rdd_with_python.py`
  used to `assert abs(2.0 - 2) < 1e-12`, which is `assert abs(0.0)` and cannot
  fail. Both now run the port. (`padjust` is 108 of the 248 -- it runs two
  p-value vectors through five methods since v0.163.0, up from one vector.)
- **The references are not equally strong, so neither is the claim:**
  - `padjust` runs `statsmodels.stats.multitest.multipletests` -- the *actual*
    upstream library the port delegates to. `rdd` reimplements the
    local-linear WLS from `rdd.mbt`'s definition and agrees to **4.8e-15**.
    `gain_statistics` is checked against two independent references on a fixture
    built so all six branches are taken.
  - The rest compare against a population target or an independent estimate on
    the port's own data. That catches a regression; it is not bit-equivalence.
- **None of them compare against the real `doubleml` wheel**; most restate the
  upstream formula in Python. The wheel is what `doubleml-for-py` is, and
  matching it is stricter than what is actually being done.
- **One parity gap closed, one still open.** `tsbh` now matches statsmodels
  **bit for bit**: `tsbh_p_adjust` runs statsmodels' own lambda search
  (`n0 = m - r1` from the stage-1 rejections, `alpha_star = alpha*m/n0`, then
  rescale by `n0/m`) instead of a global Storey-2002 rescale. Measured
  `max |moonbit - statsmodels| = 0` on both fixture vectors, so the validator
  gates it at exact equality rather than at a tolerance. `tsby` still uses the
  old estimator and still diverges from `fdr_tsbky` -- but **not** by a constant
  factor: measured `max |port - statsmodels| = 0.1595`, ratio spanning
  0.5129 ... 1.1970. It has no validator rows, so nothing in CI would catch a
  drift in it.

**Each rewritten validator has been observed failing.**
`_verify/_parity_mutation_1650.py` perturbs the emitter once per validator and
requires a non-zero exit: **11 of 11 killed**, tree restore verified by sha256.
One mutation survived and was *documented rather than fixed* -- changing the
`padjust` p-vector's first entry -- because the validator feeds that vector to
statsmodels itself, so it is the check's input, not its expected value.

**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell "the
port is arithmetically identical to the reference" apart from "the port lands
within 1e-4 of it". `validate_bitexact_with_python.py` compares IEEE-754 bit
patterns instead, against `examples/bitexact/`. Measured scope, not assumed --
re-measured on `moon 0.1.20261016` vs CPython 3.13.14, unchanged from the
`moon 0.1.20261012` vs CPython 3.14 pair it was first taken on:

| operation | bit-exact | why |
|---|---|---|
| `+ - * /` | yes | IEEE-754 requires correct rounding, so same operands in the same order MUST agree |
| `sqrt` | yes | same guarantee -- **6 / 6** measured |
| `cos`, `sin` | observed 6 / 6 | agreement today, **not** guaranteed: neither is correctly rounded |
| `ln` | **5 / 6** | `ln(3.0)` differs by exactly 1 ULP: MoonBit `1.0986122886681096`, CPython `1.0986122886681098` |

Because `box_muller_pair` uses `ln`, `cos` and `sin`, **no random-number DGP in
this package can be bit-exact against CPython**, and neither can anything routed
through BLAS/LAPACK (numpy reduces with pairwise summation; LAPACK blocks its
pivots). The check therefore asserts the surface where bit-exactness is
guaranteed -- **25 / 25 items and 6 / 6 RNG keys, currently identical** -- and
prints the rest as deliberately not asserted, so the absence is not mistaken
for an oversight. A mutation battery (`_verify/_bitexact_mutation_1640.py`)
confirms the gate discriminates: all four mutations killed, including a
truncated and a mis-tiled RNG key.

**Acceptance-criteria traceability** lives in
`features/moonbit_doubleML_acceptance.feature`: 6 `Feature`, 24 `Scenario`, 80
Given/When/Then steps. Its 24 `# mapped to:` annotations cite **29** test
names (26 distinct -- one annotation wraps onto a following comment line and
is joined). **All 29 resolve**: 26 against real `test` / `fn panic_*`
declarations, 3 prose-exempt (they name a file or a concept, e.g.
`padjust dispatcher tests in did_multi_test.mbt`). The MoonBit tests are the
executable form -- there is no separate Gherkin runner.

**Coverage is two-tier, and the tiers are not the same size.** The QA LOOP
(`.github/scripts/qa_loop/`, v0.162.0) registers **31 checks** over the **22**
required activities: **22 in `fast` scope**, which CI runs on every push and again
before publishing, and **9 in `full` scope**, which CI does **not** run as a scope.

- fast (22): `format`, `static_code_check`, `duplicate_code`, `dependencies`,
  `gherkin`, `qa_process`, `pyexample`, `pyexample_suite`,
  `pyexample_did_cs_binary`, `pyexample_did_binary`, `pyexample_lplr`,
  `pyexample_pq`, `pyexample_policytree`, `pyexample_rdd`,
  `pyexample_cs2021`, `contract`, `e2e`, `security_sast`, `perf_test`,
  `benchmark`, `coverage`, `quality_metrics`
- full (9): `static_analysis`, `unit_tests`, `component_tests`, `integration`,
  `api_test`, `security_dast`, `fuzz`, `mutation`, `load_stress`

CI deliberately runs **fast only** as a scope, and the reason is that most of
the full scope re-measures what other jobs already measure: `unit_tests` and
`component_tests` re-run `moon test`, which `moon-test` (x4 backends) already
does; `integration` re-runs all 24 Python cross-checks, which
`python-cross-check` already does; and `static_analysis` re-runs `moon check
--deny-warn`, which `publish.yml` already does before it publishes.
Re-measuring them would multiply release time for no new information.

**What that leaves uncovered is named here rather than left to be inferred.**
Neither `check.yml` nor `publish.yml` passes `--full`, so of the 9 `full`-scope
checks **2 run in CI** -- `api_test` and `security_dast`, pulled out
explicitly by `check.yml` (`--only api_test,security_dast`) -- and **7 run in
no CI workflow at all**: `static_analysis`, `unit_tests`, `component_tests`,
`integration`, `fuzz`, `mutation` and `load_stress`. For the first four the
*subject* is covered by another job (the commands above), but the check itself
is not, and one of them adds a property nothing else has: `integration` proves
that each of the 24 validators actually **spawned MoonBit**, which
`python-cross-check` does not require -- it requires a zero exit code and a
trailing `PASS`. `fuzz`, `mutation` and `load_stress` are covered by nothing
at all: no workflow runs them, so their verdicts are local measurements only.
`moonbit_doubleML/lplr.mbt` states the same about `fuzz` in the source.

**Still not covered, so not claimed.** The `coverage` check is a
test-reachability proxy, not instrumented line coverage. There is no
dependency-vulnerability scan -- `moon update` resolves versions, it is not an
audit. `mutation` kills three mutants on one kernel, not a whole-codebase
surviving-mutant ledger, and no CI workflow runs it. `examples/fuzz/` has no
crash-regression corpus, and its seed argument is **ignored** -- `fn main`
takes no parameters -- so the fuzz check replays one fixed seed (20260824)
three times rather than sweeping seeds: it is a re-run of one case, not a
fuzz, and no CI workflow runs it either. And the two declared `moon.mod`
dependencies -- `moonbit-community/sqlite3@0.2.3`
and `moonbitlang/async@0.22.5` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`2 declared; non-conforming:
['moonbit-community/sqlite3@0.2.3']; declared but unreferenced by library code:
['moonbit-community/sqlite3@0.2.3', 'moonbitlang/async@0.22.5']`) rather than
passing quietly. Removing them is an open call, not an oversight.

### Reproducing CI locally

`.github/scripts/ci_local.py` runs these jobs on this machine. It executes the
`run:` steps **straight out of the workflow YAML** rather than from a
hand-maintained copy -- a copy drifts the first time someone edits a workflow,
and a simulator that lies about what CI does is worse than no simulator.

```
python .github/scripts/ci_local.py list        # which jobs exist, and their steps
python .github/scripts/ci_local.py provision   # build the WSL guest toolchain
python .github/scripts/ci_local.py run --jobs "qa-loop"
python .github/scripts/ci_local.py run --all --release-tag v0.164.11
python .github/scripts/ci_local.py selftest    # prove the simulator can fail
```

`--release-tag` sets `$GITHUB_REF_NAME`. It is not cosmetic: `publish.yml`'s
`Resolve release version` reads that variable to decide what it is about to
publish, and with it unset the tag comes out empty and the job dies on
`Release tag must use the v* format, got:`.

It runs against `git archive <ref>`, so it sees a pristine tracked checkout --
no untracked scratch, no dirty tree -- and every step goes through `bash -e`,
which is the shell string GitHub logs. The checkout is a real git repository,
because a step is allowed to rely on that (`publish.yml` gates on
`git diff --exit-code`). Four verdicts, kept distinct on purpose:

| Verdict | Means |
|---|---|
| `PASS` | the step ran and succeeded |
| `FAIL` | the step ran and failed -- a real defect |
| `SKIP` | a `uses:` step; deliberately not simulated, never a silent PASS |
| `BLOCKED` | **this machine** lacks a tool the step needs; nothing was proven |

`BLOCKED` exists because "the runner has `python` and this box does not" is not
a red build. It is cross-checked with `command -v` in the guest, so a command
the guest *does* have and that fails anyway still reports `FAIL`.

A step whose entire body is **provisioning a named tool** is also `BLOCKED`
when it fails, because it downloads tools and asserts nothing about the
repository -- so its outcome is a fact about this machine's network, not about
the ref. The real case is `Install typos`: it is `curl ... | tar zxf -` with
no `--max-time`, and on this machine the asset CDN delivered 4,350,067 of
6,365,610 bytes and then timed out, so `curl` exited non-zero and piped a
truncated stream into `tar`. That reported `tar: Error is not recoverable` and
was scored `FAIL` twice on a tree whose every code gate was green. The same
fetch also failed a third time as `curl: (55) SSL_read: unexpected eof` in 91s,
and succeeded a fourth time in 274s -- the intermittency is the network, and the
failure text differs each time, which is why matching on the error text was the
wrong lever.

That fourth run is the useful control: with the download restored, `BLOCKED`
becomes `PASS` and `static_code_check` reports
`typos: 8 finding(s) in 1 tracked file(s) [pyexample_lplr.py]` -- so on a green
run the typos gate really does run, and "QA loop green" here does include it.

The obvious guard -- "downgrade only when the tool is still absent" -- is
*wrong*: the guest had `typos` on disk from an earlier successful run, so that
rule would have kept reporting red for a transfer the gate does not need. So
the marker decides the verdict, and `command -v` only enriches the detail text.
That probe has to run with the **step's own PATH**: the tool reaches later
steps through the `$GITHUB_PATH` line this same step writes, so probing with the
guest default reports "not available" for a tool that is sitting at
`/home/ryx/.cargo/bin/typos`. A detail line that contradicts the run's own
evidence is worse than no detail line.

`selftest` is the guard on the guard: every discriminating rule has a paired
control arm, so a gate that cannot fail cannot pass here either. **22
self-tests.** Eight simulator bugs it has caught, every one of which read as a
project failure:

- Windows `text=True` put a `\r` on every line of the script, so
  `>> $GITHUB_PATH` wrote to a file named `<path>\r\r`. The write *succeeded*
  (rc 0, empty stderr), and the next step could never find the tool it
  installed.
- `to_wsl` was not idempotent, turning a guest path `/mnt/c/...` into
  `/mnt/d/mnt/c/...` when a PATH entry was read back.
- `${{ matrix.target }}` was never expanded, so all four backends ran the
  literal text and bash reported "bad substitution" -- four FAILs that looked
  like the package was built for the wrong backend.
- `git archive` produced files but not a repository, so
  `git diff --exit-code` exited 129 with a usage dump naming `--output` -- read
  as `moon info` having the wrong flags.
- The index was written by Windows git (`autocrlf=true`, normalizing
  `CHANGELOG.md` to LF) and read by Linux git, so a **pristine** checkout
  reported a diff.
- `$GITHUB_REF_NAME` was never set, so `Resolve release version` failed on an
  empty tag.
- `--engine none` was advertised by `--help` and rejected by `plan()`.
- `publish.yml` runs `moon publish` and `gh release` from plain `run:` steps, so
  nothing structural stopped a local `run --all` from shipping a release. Such
  steps are now refused, never executed.

Not simulated: `uses:` steps beyond provisioning, secrets, `GITHUB_TOKEN`,
release publishing, `steps.*.outputs`, and the exact OS image (WSL Ubuntu is
close to `ubuntu-latest`, but not equal to it).

- All randomness flows through `chacha8_rng(seed)` (`seed.mbt`).
  Default `seed=3141`; same seed => byte-identical DGP outputs.
- Python reference scripts `validate_*_with_python.py` reproduce
  the upstream `doubleml-for-py` numbers. CI runs each one and requires both a
  zero exit code and a trailing `PASS` line on stdout.
- The parity tolerance lives in the **Python** validators, not in a
  MoonBit test file. `validate_*_with_python.py` compares MoonBit's
  output against a hand-rolled reference under a per-script tolerance
  -- `max(model_tol, 2.0 * handrolled_se)`, with `model_tol = 0.1` in
  the IRM script and `MODEL_TOL = 0.3` in the APOS and DIDCSBinary
  scripts. `dgp_recovery_test.mbt` is a MoonBit test file and
  enforces its own measured SE-relative bands; it contains no
  `MODEL_TOL` and no `handrolled_se` (measured: 0 hits of either
  anywhere in the library's sources).
- v0.62.0 verified counts: `moon test` 485 / 485 (native & wasm &
  js) and 491 / 491 (wasm-gc); `python _verify/run_all_validators.py`
  23 / 23 PASS in ~70 s. `moon fmt --check` is now clean (was
  failing on every release since v0.57.0).
- v0.63.0 verified counts: `moon test` 491 / 491 (native & wasm &
  js) and 497 / 497 (wasm-gc); 23 / 23 Python cross-validators PASS
  in ~90 s. Adds 6 new wbtests (`v063_wbtest.mbt`) covering
  APO learner plumbing + APOS bootstrap/confint + BLP plumbing.
- v0.64.0 verified counts: `moon test` 500 / 500 (native, wasm, js)
  and 506 / 506 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~73 s. Adds `bootstrap()` to nine remaining estimators (SSM, DID,
  DIDBinary, DIDCSBinary, LPQ, PQ, QTE, DIDCS, BLP) via four new
  shared inner helpers in `bootstrap_helper.mbt`. RDD and
  PolicyTree bootstrap deferred to v0.65.0 (kernel-weighted n_local
  IF and tree IF need a different multiplier formula).
- v0.65.0 verified counts: `moon test` 506 / 506 (native, wasm, js)
  and 512 / 512 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~107 s. Adds `DoubleMLAPO::fit_cluster` (with `DoubleMLAPOS`
  inheriting the cluster dispatch transparently) and `tune()` on
  IRM / PLIV / IIVM / APO. PQ / QTE `fit_cluster` deferred to
  v0.66.0 (`solve_pq` bisection requires a folds-override refactor
  for true cluster-aware cross-fitting).
- v0.66.0 verified counts: `moon test` 517 / 517 (native, wasm, js)
  and 523 / 523 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~48 s. Adds `sensitivity_analysis()` on eight IRM-style estimators
  (PLR / IRM / PLIV / IIVM / APO / DID / DIDBinary / DIDCSBinary)
  via a shared `irm_style_sensitivity` helper; `confint(joint=true)`
  on 3 multi-theta estimators (APOS / QTE / DIDCS) using a
  max-|t|-bootstrap critical value. Sensitivity on LPQ / PQ /
  QTE / SSM / RDD / BLP / PolicyTree and PQ / QTE `fit_cluster`
  deferred to v0.67.0.
- v0.67.0 verified counts: `moon test` 522 / 522 (native, wasm, js)
  and 528 / 528 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~47 s. Refactors `solve_pq` to accept `folds?` and adds
  `fit_cluster` on `DoubleMLPQ` / `DoubleMLQTE` (cluster-aware
  folds + unit-level cluster-robust SE). Adds `confint(joint?)`
  API parity to 9 single-theta estimators. Adds
  `sensitivity_analysis()` on LPQ / PQ via a shared
  `single_psi_sensitivity` helper (centered-IF form).
- v0.68.0 verified counts: `moon test` 524 / 524 (native, wasm, js)
  and 530 / 530 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~47 s. Adds `sensitivity_analysis()` on SSM (psi_a = -1,
  residuals = y - g_d1_hat) and APOS (per-level re-fit pattern).
  DIDCS / BLP / RDD / PolicyTree sensitivity deferred to v0.69.0+
  (each requires a structural IF / nuisance-persistence plumbing
  beyond the shared helpers already in place).
- v0.69.0 verified counts: `moon test` 528 / 528 (native, wasm, js)
  and 534 / 534 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Closes the v0.69.0 sensitivity cycle: BLP (closed-form OLS
  precision matrix), DIDCS (per-cell long-format panel),
  RDD (kernel-weighted local polynomial), and PolicyTree
  (per-leaf DFS IRM-style decomposition).
- v0.86.0 verified counts: `moon test` 623 / 623 (native, wasm, js)
  and 629 / 629 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Adds the shared `sandwich_variance(kind, ...)` dispatch to
  `sandwich.mbt` and the `sandwich_se(kind)` /
  `cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`
  triple on `DoubleMLIIVM`, `DoubleMLPLIV`, `DoubleMLDID`, and
  `DoubleMLCVAR` (coverage 2 -> 6 of 22). `DoubleMLLPQ` is
  deliberately skipped: its Jacobian `deriv` is a `fit()` local and
  is never persisted, and its `psi` is the centered check function
  at the bisection root with no `coef * psi_a + psi_b` split, so
  neither `psi_a` nor `M_inv` is recoverable post-fit. The 6 new
  white-box tests assert the HC1 `sqrt(n/(n-1))` identity, the
  independently recomputed HC0 variance, the leverage-driven
  ordering, exact singleton-cluster equality with the IID HC0, and
  the bias-correction identity -- not just finiteness.
- v0.90.0 verified counts: `moon test` 648 / 648 (native, wasm, js)
  and 654 / 654 (wasm-gc). **BREAKING NUMERICAL CHANGE:**
  `sandwich_se` / `cluster_sandwich_se` and every multiplier
  `bootstrap()` t-stat change for the 11 affected estimators; `se()`
  is unchanged and remains the reference. The sandwich family and
  the bootstrap evaluated `E[psi_a + theta * psi_b]`, a different
  function from `var_est`'s `E[theta * psi_a + psi_b]` whose root is
  not `theta_hat`; on a fixed DGP the resulting `sandwich_se(HC0)`
  was off by up to ~1100x. v0.90.0 adds one `psi_at(coef, psi_a,
  psi_b)` helper in `sandwich.mbt` and routes all 13 psi-construction
  sites through it. `DoubleMLDIDCrossSection` was deliberately NOT
  routed then, on the stated ground that it is a projection
  (`argmin_theta`) estimator with the offset / slope roles
  inverted and its own `se` formula -- **v0.102.0 removed that
  exception**: upstream `DoubleMLDIDCS` is a `LinearScoreMixin`
  subclass on the plain linear score, so this port's `fit` now
  routes through `var_est` like the others and its sandwich uses
  the same order. See `CHANGELOG.md` v0.102.0, including the
  measured point estimate and SE.
  `DoubleMLLPLR` also persists its IF components in the inverted
  (offset, slope) order and is handled by passing the two arrays
  swapped at its single call site -- its bootstrap output is
  bit-identical to v0.89.0. (The list above was not backfilled for
  v0.70-v0.85 or v0.87-v0.89; see `CHANGELOG.md` for those entries.)

##Attribution

`moonbit_doubleML` is a port of the upstream
[`DoubleML/doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py)
package (BSD 3-Clause License). Upstream's 19 name-matched estimator
classes are re-implemented in pure MoonBit with the same score
formulae and variance estimators, as is its RDD implementation
(`RDFlex` upstream, `DoubleMLRDD` here). `DoubleMLPLPR`,
`DoubleMLLPLR` and `DoubleMLDIDCSBinary` are **not** MoonBit-only -- all
three ship upstream, and are compared against it. The last candidate
for a port-only estimator, `DoubleMLDIDCrossSection`, is upstream's
`DoubleMLDIDCS` under a different name. One estimator does have **no
1:1 upstream class**: `DoubleMLDIDCS`, this port's variant of
upstream's multi-period `DoubleMLDIDMulti` -- see the estimator table
and `_verify/UPSTREAM_PROVENANCE.md`.

#### Differences from upstream `doubleml-for-py`

- Native MoonBit package layout, type system, and test organization.
- Independent implementations of `Matrix`, linear / logistic
  regression, stratified K-fold, ChaCha8 PRNG, and Kahan summation
  in MoonBit; **no NumPy / scikit-learn dependency**.
- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical
  MoonBit-idiomatic API, with optional JSON in/out for native /
  wasm-gc / wasm / js backends (Serverless / Wasm / edge
  deployments).
- Behaviour-level parity check via the 24 Python reference scripts: 23
  compare under `within-tolerance equivalence`, and one
  (`validate_bitexact_with_python.py`) compares IEEE-754 bit patterns
  instead. The tolerance tier keeps the port resilient to upstream
  refactors; the bit-exact tier is where it must not drift at all.
- Strict dependency rule (see above): only `moonbitlang/*` official
  packages. Minimal supply-chain surface.

##Used By

- [`riantr/pyroduct`](https://mooncakes.io/docs/riantr/pyroduct) --
  downstream consumer that models Ren Yongxiang's MA thesis
  (Gadamer/Habermas, Shanghai Academy of Social Sciences 2008)
  plus its appendix as runnable multi-agent state machines. Its
  `dmlref` package cross-checks its own from-scratch DoubleML
  PLR against `riantr/moonbit_doubleML` v0.163.3 (its current pin):
  same nuisance (OLS), `n = 400`, true `theta = 1.5`, `theta` delta
  `0.017` (1.667 vs 1.685) and `se` delta `0.001` (0.153 vs 0.152).
  Source lives on
  [`gitee.com/ren-yongxiang/pyroduct`](https://gitee.com/ren-yongxiang/pyroduct).
- `examples/api_server/` -- this repo's HTTP service.
- `examples/consumer_demo/` -- minimal end-to-end PLR showing the
  consumer-side import pattern (`moon add riantr/moonbit_doubleML`).