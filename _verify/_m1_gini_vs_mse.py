"""Is the MSE/Gini split choice equivalent on BINARY labels?

M1 in mut_v117_learner.ps1 survived, so check the algebra rather than
just believing the harness.

For a node with n_left rows of binary y and mean p_left:
    sum_{i in left} (y_i - p_left)^2 = n_left * p_left * (1 - p_left)
                                   = (n_left / 2) * [2 p_left (1-p_left)]
                                   = (n_left / 2) * gini_left

So the weighted MSE reduction and the weighted Gini reduction differ by
a CONSTANT factor of 2 on the whole score, for every candidate split.
Minimising one minimises the other, and the strict `<` tie-break
selects the same split in both cases.
"""
import itertools
import random

def mse_score(labels, s):
    l = labels[:s]; r = labels[s:]
    def ss(v):
        if not v: return 0.0
        m = sum(v)/len(v)
        return sum((t-m)**2 for t in v)
    return ss(l) + ss(r)

def gini_score(labels, s):
    l = labels[:s]; r = labels[s:]
    def g(v):
        if not v: return 0.0
        p = sum(v)/len(v)
        return 2*p*(1-p)
    return len(l)*g(l) + len(r)*g(r)

random.seed(11)
worst = 0.0
same = 0
total = 0
for trial in range(3000):
    n = random.randint(4, 9)
    labels = [float(random.randint(0, 1)) for _ in range(n)]
    best_m = min(range(1, n), key=lambda s: mse_score(labels, s))
    best_g = min(range(1, n), key=lambda s: gini_score(labels, s))
    total += 1
    if best_m == best_g:
        same += 1
    for s in range(1, n):
        m, g = mse_score(labels, s), gini_score(labels, s)
        if m == 0.0:
            continue
        worst = max(worst, abs(m*2 - g)/abs(g))
print("trials:", total, " argmin agrees:", same)
print("max relative deviation of (2*MSE) from Gini over all splits:", worst)
print()
print("non-binary control -- MSE and Gini must now DISAGREE:")
cnt = 0
for trial in range(3000):
    n = random.randint(4, 8)
    labels = [float(random.randint(0, 3)) for _ in range(n)]
    if min(labels) == max(labels):
        continue
    bm = min(range(1, n), key=lambda s: mse_score(labels, s))
    bg = min(range(1, n), key=lambda s: gini_score(labels, s))
    if bm != bg:
        cnt += 1
print("  fraction of multi-class trials where the argmin differs:", cnt, "/ 3000")
