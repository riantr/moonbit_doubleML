"""Direct comparison: the port's `var_est_cluster` vs upstream's own
`var_one_way_cluster`, on the same explicit arrays.

`var_est_cluster` is currently pinned only to a hand-computed oracle
(`plpr_var_est_cluster_reference`). This measures it against the FUNCTION that
upstream actually uses, on a fixture chosen so the two implementations could
disagree if they were different:

  - non-uniform cluster sizes (2, 3, 4), so a `sum / n_c` that silently used the
    wrong denominator cannot pass;
  - folds that SPLIT clusters (a cluster with rows in two different folds), so
    "which rows does a cluster contribute" is observable -- upstream selects
    `cluster_var == i` GLOBALLY, not restricted to the test set;
  - a cluster that appears in NO test set, so the `len(I_k)` normalisation is
    exercised against an unequal count.
"""
import numpy as np

from doubleml.tests._utils_cluster import var_one_way_cluster

# --- fixture: 9 observations, 3 clusters of sizes 4, 3, 2 -------------------
psi = np.array([1.0, -2.0, 0.5, 3.0, -1.0, 2.5, -0.25, 4.0, -3.5])
psi_a = np.array([1.0, 2.0, -1.0, 1.0, 3.0, 1.0, 2.0, -2.0, 1.0])
cluster_var = np.array([0, 0, 0, 0, 1, 1, 1, 2, 2])
# fold assignment: cluster 0 splits across folds 0 and 1; clusters 1 and 2 are
# whole. Cluster 1 lands in fold 1, cluster 2 in fold 2, so fold 2 holds one
# cluster and I_2 = {2} -- normalisation by an unequal count.
fold_of = np.array([0, 0, 1, 1, 1, 1, 1, 2, 2])
n_folds = 3

smpls = [(np.setdiff1d(np.arange(len(psi)), np.nonzero(fold_of == k)[0]),
          np.nonzero(fold_of == k)[0]) for k in range(n_folds)]

var_up = var_one_way_cluster(psi, psi_a, cluster_var, smpls)
se_up = np.sqrt(var_up)

# --- the same arithmetic, written the way `var_est_cluster` does it ---------
# unit_rows  : rows per cluster, ascending
# unit_fold  : which fold each cluster's rows belong to -- but upstream picks
#              I_k from the cluster ids PRESENT IN THE TEST SET, and takes ALL
#              rows of such a cluster globally. Cluster 0 is present in folds 0
#              and 1, so it contributes its full global psi sum to BOTH.
def port_formula(psi, psi_a, cluster_var, fold_of, n_folds, n_clusters, npc):
    gamma = 0.0
    j_hat = 0.0
    for f in range(n_folds):
        test = np.nonzero(fold_of == f)[0]
        I_k = np.unique(cluster_var[test])
        m = len(I_k)
        if m == 0:
            continue
        w = 1.0 / m
        for c in I_k:
            ind = cluster_var == c          # GLOBAL, as upstream does
            s = psi[ind].sum()
            gamma = gamma + w * s * s
        j_hat = j_hat + w * psi_a[test].sum()
    j = j_hat / npc
    g = gamma / npc
    return np.sqrt(g / (n_clusters * j * j))


se_port = port_formula(psi, psi_a, cluster_var, fold_of, n_folds, 3, n_folds)

print("psi        ", psi)
print("psi_a      ", psi_a)
print("cluster_var", cluster_var)
print("fold_of    ", fold_of)
print()
print("upstream var_one_way_cluster : %.17g" % var_up)
print("port     var_est_cluster     : %.17g" % (se_port ** 2))
print("rel gap                       : %.3e" % (abs(se_port - se_up) / se_up))
print()
print("per-cluster contributions (upstream picks I_k from the TEST SET, then")
print("takes the cluster's rows globally):")
for f in range(n_folds):
    test = np.nonzero(fold_of == f)[0]
    Ik = np.unique(cluster_var[test])
    print("  fold %d: test rows %-14s I_k=%-9s m=%d  sum(psi_a[test])=%.4f"
          % (f, list(test), list(Ik), len(Ik), psi_a[test].sum()))
print()
print("A cluster present in TWO folds is counted in BOTH. That is upstream's")
print("arithmetic -- but note the port CANNOT express it: `unit_fold[u]` is")
print("one fold id per UNIT, because the port's cross-fitting folds whole")
print("units. So the two differ in what partition they accept, not in the")
print("variance formula. Fixture B below is unit-aligned and is the one the")
print("MoonBit test gates.")
print()

# --- Fixture B: unit-aligned, so `var_est_cluster` can express it -----------
# 4 clusters of UNEVEN size (4, 2, 3, 4) over 3 folds, whole-cluster:
#
#   fold 0 -> {u0}      m = 1
#   fold 1 -> {u1, u2}  m = 2
#   fold 2 -> {u3}      m = 1
#
# so 1/m is exercised at both 1 and 2, cluster sizes are unequal, and
# m != n_folds, which is the case a constant divisor would get wrong.
#
# NOTE `unit_fold` is PER UNIT (length = n_units = 4), not per row. An earlier
# version of this fixture passed the 13 per-row fold ids instead;
# `var_est_cluster` reads `unit_fold[u]` for u in 0..n_units, so folds 1 and 2
# came back with zero units and `require(m > 0)` fired. The MoonBit test caught
# it -- and the Python side had agreed with upstream at 0.0e+00 the whole time,
# because `port_formula` here is a per-row re-implementation, so it was
# comparing upstream's function with itself and could not see the difference.
nB = 13
psiB = np.array([(-1.0) ** i * (0.5 + (i % 4)) for i in range(nB)])
psiBa = np.array([1.0, -2.0, 0.5, 3.0, -1.0, 2.5, -0.25, 4.0, -3.5,
                  1.0, 2.0, -1.0, 0.75])
clB = np.array([0] * 4 + [1] * 2 + [2] * 3 + [3] * 4)
unitRowsB = [[0, 1, 2, 3], [4, 5], [6, 7, 8], [9, 10, 11, 12]]
unitFoldB = [0, 1, 1, 2]
# derive the per-row fold assignment the way the port does: unit -> fold
foldB = np.array([unitFoldB[c] for c in clB])
smplsB = [(np.setdiff1d(np.arange(nB), np.nonzero(foldB == k)[0]),
           np.nonzero(foldB == k)[0]) for k in range(3)]
varB = var_one_way_cluster(psiB, psiBa, clB, smplsB)
seB_port = port_formula(psiB, psiBa, clB, foldB, 3, 4, 3)

print("FIXTURE B (unit-aligned) -- these literals go in plpr_test.mbt")
print("  psi         ", [float(v) for v in psiB])
print("  psi_deriv   ", [float(v) for v in psiBa])
print("  unit_rows   ", unitRowsB)
print("  unit_fold   ", unitFoldB, "<- per UNIT, length %d" % len(unitFoldB))
print("  n_folds=3, n_folds_per_cluster=3, n_units=4")
print()
for f in range(3):
    test = np.nonzero(foldB == f)[0]
    Ik = np.unique(clB[test])
    print("  fold %d: rows %-18s I_k=%-9s m=%d  sum(psi_a[test])=%.4f"
          % (f, [int(v) for v in test], [int(v) for v in Ik], len(Ik),
             psiBa[test].sum()))
print()
print("  upstream var_one_way_cluster variance : %.17g" % varB)
print("  upstream                               se: %.17g" % np.sqrt(varB))
print("  port     var_est_cluster     variance : %.17g" % (seB_port ** 2))
print("  port                               se: %.17g" % seB_port)
print("  rel gap                                 : %.3e" % (abs(seB_port - np.sqrt(varB)) / np.sqrt(varB)))
print()
print("  MoonBit asserts |se - %.17g| < 1e-15" % np.sqrt(varB))

