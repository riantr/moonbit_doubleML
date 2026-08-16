"""Reference PAVA + isotonic regression output for cross-check."""
import numpy as np
from sklearn.isotonic import IsotonicRegression


def pava_ref(y, weights=None):
    """Pool-adjacent-violators algorithm matching our MoonBit port.

    y is assumed already sorted by the predictor x.
    """
    y = np.asarray(y, dtype=float)
    n = len(y)
    if n == 0:
        return np.array([], dtype=float)
    if weights is None:
        w = np.ones(n)
    else:
        w = np.asarray(weights, dtype=float)
    block_sum = []
    block_w = []
    block_size = []
    for i in range(n):
        cur_sum = y[i]
        cur_w = w[i]
        cur_size = 1
        while len(block_size) > 0:
            last_mean = block_sum[-1] / block_w[-1]
            new_mean = cur_sum / cur_w
            if last_mean <= new_mean:
                break
            cur_size = cur_size + block_size[-1]
            cur_sum = cur_sum + block_sum[-1]
            cur_w = cur_w + block_w[-1]
            block_sum.pop()
            block_w.pop()
            block_size.pop()
        block_sum.append(cur_sum)
        block_w.append(cur_w)
        block_size.append(cur_size)
    out = np.zeros(n)
    k = 0
    for s, sm, sz in zip(block_sum, block_w, block_size):
        mean = s / sm
        out[k:k + sz] = mean
        k = k + sz
    return out


def ir_predict(x, y, x_new):
    """Explicit fit + predict."""
    ir = IsotonicRegression(out_of_bounds="clip", y_min=0.0, y_max=1.0)
    ir.fit(np.asarray(x).reshape(-1, 1), np.asarray(y))
    return ir.predict(np.asarray(x_new).reshape(-1, 1))


# Test 1: simple monotonic input (sorted y)
y1 = [0.1, 0.2, 0.3, 0.4, 0.5]
x1 = [0.1, 0.2, 0.3, 0.4, 0.5]
print("Test 1 monotonic:")
print("  PAVA:", pava_ref(y1))
print("  IR  :", ir_predict(x1, y1, x1))

# Test 2: violation, sorted by x
x2 = [0.1, 0.2, 0.3, 0.4, 0.5]
y2 = [0.3, 0.2, 0.4, 0.5, 0.6]
print("Test 2 violation sorted:")
print("  PAVA:", pava_ref(y2))
print("  IR  :", ir_predict(x2, y2, x2))

# Test 3: ties
x3 = [0.1, 0.1, 0.3, 0.5, 0.5]
y3 = [0.1, 0.5, 0.1, 0.5, 0.3]
print("Test 3 ties:")
print("  PAVA on x-sorted y3:", pava_ref([0.1, 0.5, 0.1, 0.5, 0.3]))
print("  IR  :", ir_predict(x3, y3, x3))

# Test 4: full pipeline
x4 = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
y4 = [0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0]
print("Test 4 end-to-end:")
print("  IR predict:", ir_predict(x4, y4, x4))
print("  Our pava  :", pava_ref(y4))

# Test 5: CV (5-fold)
from sklearn.model_selection import cross_val_predict
pred_cv = cross_val_predict(
    IsotonicRegression(out_of_bounds="clip", y_min=0.0, y_max=1.0),
    np.array(x4).reshape(-1, 1), np.array(y4), cv=5, method="predict"
)
print("Test 5 5-fold CV:")
print("  IR cross_val_predict:", pred_cv)
