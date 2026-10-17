import inspect

import scipy
import scipy.optimize as so
import scipy.optimize._zeros_py as z

print("scipy", scipy.__version__)
src = inspect.getsource(z.newton)
i = src.find("p0 = 1.0")
if i < 0:
    i = src.find("for itr in range(maxiter)")
print("=== newton loop ===")
print(src[i:i + 2400])

rs = inspect.getsource(so.root_scalar)
j = rs.find("newton(")
print()
print("=== root_scalar -> newton ===")
print(rs[max(0, j - 700):j + 500])
