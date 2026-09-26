// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }
name = "riantr/moonbit_doubleML"

version = "0.53.0"

readme = "README.mbt.md"

repository = "https://gitee.com/ren-yongxiang/moonbit_doubleml.git"

license = "Apache-2.0"

keywords = ["doubleml", "DML", "causal-inference", "machine-learning", "debiased-estimation"]

preferred_target = "wasm-gc"

supported_targets = "native+wasm+wasm-gc+js"

description = "Pure-MoonBit port of doubleml-for-py: Double / Debiased Machine Learning for partial linear, IRM, IV, DID, SSM, APO(S), PQ, QTE, LPQ, CVaR, RDD, BLP, and policy-tree models"
