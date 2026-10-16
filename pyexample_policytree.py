#!/usr/bin/env python3
"""PolicyTree against upstream `doubleml.utils.policytree.DoubleMLPolicyTree`.

WHY THIS GATE EXISTS
====================
`examples/main` carried five estimator slots with an ANALYTIC oracle only and
no upstream gate at all: RDD, PQ, QTE, LPQ and PolicyTree. PQ/QTE/LPQ are
gated in `pyexample_pq.py`; RDD is measured divergent and deliberately has no
gate (`_verify/RDD_PARITY_1680.md`). This closes PolicyTree, the last one.

TWO CALL-SHAPE TRAPS, both found by running rather than by reading
================================================================
Upstream's signature is

    DoubleMLPolicyTree(orth_signal, features, depth=2, **tree_params)

so the argument order is REVERSED relative to the port's
`DoubleMLPolicyTree::new(features, orth_signal, ...)`, `features` must be a
`pandas.DataFrame`, and `depth` DEFAULTS TO 2 while the port's defaults to 1.
Depth is therefore pinned explicitly on both sides; leaving it to defaults
would compare a depth-1 tree against a depth-2 tree.

WHY THE COMPARISON IS LABELS, NOT STRUCTURE
===========================================
The two builders are different algorithms:

  * the port's `policy_tree_build` splits at the column MEAN; sklearn's
    threshold is a MIDPOINT between two consecutive sorted values;
  * the port's criterion is variance reduction on the RAW signal; upstream is
    gini on `bin_signal = (sign(s) + 1) / 2` weighted by `abs(s)`;
  * the port's leaf label is the sign of the mean raw signal; upstream's is
    `argmax` of the weighted class counts;
  * the port has no `min_samples_leaf` and no `ccp_alpha`; upstream defaults to
    8 and 0.01.

On a two-column design those differences put 10 of 300 rows in different
leaves. Measured, not assumed -- `_verify/POLICYTREE_PARITY_1680.md`. So what
is compared is what both algorithms DO: the full label vector over every row,
plus the split feature and the threshold. That is invariant to the threshold
convention and to the criterion, and it survives the port splitting a
zero-gain pure node at depth 2, which is a structural difference with no
effect on any prediction.

This is a deliberately weaker claim than "the estimators agree", and the
weaker claim is the true one. What this gate establishes is that the
configuration the repository SHIPS agrees exactly.

WHY THE THRESHOLD IS COMPARED WITH A TOLERANCE
==============================================
sklearn stores node thresholds as float32. The port computes in f64. The two
therefore cannot be bit-equal: on this design the gap is 9.499e-11 on a
threshold of 0.002, i.e. 4.7e-8 relative, which is 0.4x the float32 epsilon.
The bound below sits about 8x above that, so it never trips on storage and
still fails on a moved split.

WHY `random_state` IS PINNED
============================
Upstream is NON-DETERMINISTIC without it: two fits in one process with
`random_state=None` produced different trees here. `random_state` reaches the
underlying `DecisionTreeClassifier` through `**tree_params`, so it is pinned
explicitly rather than left to the process-global stream.

FAILS CLOSED: if `moon run` cannot be executed, or its output cannot be
parsed, or the independently rebuilt data disagrees with the emitter's, the
verdict is FAIL.
"""

import argparse
import io
import json
import os
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))

N = 500
DEPTHS = (1, 2)

# 8x the measured 4.7e-8 float32 storage gap. See the module docstring.
THRESH_RTOL = 1e-6

# Summation order differs between the two languages, so the fingerprint is
# compared relatively. The measured gap here is ~4e-15, so this is five orders
# of magnitude of headroom -- a perturbed row moves it far more than that.
FINGER_RTOL = 1e-12


def build():
    """`examples/main`'s PolicyTree design, rebuilt independently. Integer
    arithmetic only, so CPython and MoonBit construct the same numbers."""
    half = N // 2
    x, s = [], []
    for i in range(N):
        z = (float(i) - float(half)) / float(half)
        x.append(z)
        s.append(-1.0 if z < 0.0 else 1.0)
    return np.array(x).reshape(-1, 1), np.array(s)


def run_emitter():
    r = subprocess.run(
        ["moon", "run", "examples/parity", "--target", "native"],
        cwd=HERE, capture_output=True, text=True, timeout=1800,
    )
    if r.returncode != 0:
        raise RuntimeError(
            "moon run examples/parity exited %d: %s"
            % (r.returncode, (r.stderr or r.stdout)[:600])
        )
    return r.stdout


def parse_section(out, name):
    lines = out.splitlines()
    try:
        start = next(i for i, l in enumerate(lines)
                     if l.strip() == "section " + name)
    except StopIteration:
        raise RuntimeError("emitter emitted no section %r" % name)
    vals, data = {}, {}
    for l in lines[start + 1:]:
        s = l.strip()
        if s == "end":
            break
        if s.startswith("val "):
            p = s.split()
            vals[p[1]] = float(p[2])
        elif s.startswith("data "):
            p = s.split()
            data[p[1]] = [float(v) for v in p[3:]]
    return vals, data


def upstream_fit(X, s, depth, random_state):
    from doubleml.utils.policytree import DoubleMLPolicyTree
    feat = pd.DataFrame(X, columns=["x0"])
    pt = DoubleMLPolicyTree(np.asarray(s, dtype=float), feat, depth=depth,
                            random_state=random_state)
    pt.fit()
    return pt


def close(a, b, rtol):
    return abs(a - b) <= rtol * max(abs(a), abs(b), 1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="accepted for symmetry with the other pyexample_* gates")
    ap.add_argument("--json", help="write the measurement record here")
    args = ap.parse_args()

    print("=" * 76)
    print("PolicyTree port vs upstream doubleml.utils.policytree")
    print("=" * 76)

    X, s = build()

    print("--- 1. the two constructions of the design ---")
    # A fingerprint, not a class count. `pt_neg` alone survives any
    # permutation that reshuffles every row; the second moment does not.
    fp = {
        "pt_n": float(N),
        "pt_sum_x": float(np.sum(X)),
        "pt_sum_x2": float(np.sum(X * X)),
        "pt_sum_s": float(np.sum(s)),
        "pt_neg": float((s < 0).sum()),
    }
    print("    %-12s python=%.12f" % ("pt_n", fp["pt_n"]))

    out = run_emitter()
    vals, data = parse_section(out, "policytree")

    ok = True
    for k, want in fp.items():
        if k not in vals:
            print("    %-12s MISSING from emitter" % k)
            ok = False
            continue
        got = vals[k]
        same = close(got, want, FINGER_RTOL)
        print("    %-12s port=%.12f  rebuilt=%.12f  %s"
              % (k, got, want, "ok" if same else "DISAGREE"))
        ok = ok and same

    if not ok:
        print("\nREFUSING to compare: the two constructions of the design "
              "disagree.")
        return 1

    # A control on the UPSTREAM side: prove the pinned seed reproduces before
    # trusting any comparison made with it.
    print("\n--- 2. upstream determinism under the pinned seed ---")
    for depth in DEPTHS:
        a = upstream_fit(X, s, depth, 0).policy_tree.predict(
            pd.DataFrame(X, columns=["x0"]))
        b = upstream_fit(X, s, depth, 0).policy_tree.predict(
            pd.DataFrame(X, columns=["x0"]))
        same = list(a) == list(b)
        print("    depth=%d  two fits identical: %s" % (depth, same))
        ok = ok and same

    print("\n--- 3. split feature, threshold, labels and probes ---")
    probe = pd.DataFrame(np.array([[-0.5], [0.5]]), columns=["x0"])
    rows = []
    for depth in DEPTHS:
        pt = upstream_fit(X, s, depth, 0)
        tree = pt.policy_tree.tree_

        up_labels = [int(v) for v in
                     pt.policy_tree.predict(pd.DataFrame(X, columns=["x0"]))]
        up_probe = [int(v) for v in pt.policy_tree.predict(probe)]
        port_labels = [int(v) for v in data["pt%d_labels" % depth]]
        port_probe = [int(v) for v in data["pt%d_probe" % depth]]

        up_feat = int(tree.feature[0])
        up_threshold = float(tree.threshold[0])
        port_feat = int(vals["pt%d_split_feature" % depth])
        port_threshold = vals["pt%d_split_value" % depth]

        feat_ok = up_feat == port_feat
        rel = abs(port_threshold - up_threshold) / max(abs(up_threshold), 1e-300)
        thr_ok = rel <= THRESH_RTOL
        lab_ok = up_labels == port_labels
        prb_ok = up_probe == port_probe

        print("\n  depth=%d" % depth)
        print("    split feature : port %d  upstream %d  %s"
              % (port_feat, up_feat, "ok" if feat_ok else "DISAGREE"))
        print("    split value   : port %.17g" % port_threshold)
        print("                   up  %.17g" % up_threshold)
        print("                   rel gap %.3e (bound %.0e)  %s"
              % (rel, THRESH_RTOL, "ok" if thr_ok else "DISAGREE"))
        if lab_ok:
            ones = sum(up_labels)
            first1 = next(i for i, v in enumerate(up_labels) if v == 1)
            print("    labels        : all %d rows agree  (ones=%d, "
                  "first 1 at row %d)" % (len(up_labels), ones, first1))
        else:
            bad = [i for i, (a, b) in enumerate(zip(port_labels, up_labels))
                   if a != b]
            print("    labels        : %d of %d rows DISAGREE, first at %s"
                  % (len(bad), len(up_labels), bad[:8]))
        print("    probe [-0.5, 0.5] : port %s  upstream %s  %s"
              % (port_probe, up_probe, "ok" if prb_ok else "DISAGREE"))

        ok = ok and feat_ok and thr_ok and lab_ok and prb_ok
        rows.append(dict(depth=depth, split_feature_port=port_feat,
                         split_feature_upstream=up_feat,
                         split_value_port=port_threshold, split_value_upstream=up_threshold,
                         threshold_rel_gap=rel,
                         labels_agree=bool(lab_ok),
                         label_disagreements=len(port_labels) - sum(
                             1 for a, b in zip(port_labels, up_labels) if a == b),
                         probe_port=port_probe, probe_upstream=up_probe))

    print("\n" + "=" * 76)
    if ok:
        print("RESULT: PolicyTree upstream parity: PASS")
    else:
        print("RESULT: PolicyTree upstream parity: FAIL")
    print("=" * 76)

    if args.json:
        with io.open(args.json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(dict(agree=bool(ok), n=N, depths=list(DEPTHS),
                           threshold_rtol=THRESH_RTOL, rows=rows), fh, indent=2)
    return 0 if ok else 1


if __name__ == "__main__":
    warnings.filterwarnings("ignore")
    sys.exit(main())
