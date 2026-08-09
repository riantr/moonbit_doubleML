# Production-ready 推进派发清单

> 作者：verifier session `mvs_ca67c4c3aafa47798ffc4d08af01549a`
> 上游 review：见 verifier session transcript（`mavis session messages --session-id mvs_ca67c4c3aafa47798ffc4d08af01549a`）
> 上游失败原因汇总：`/linalg.mbt:24` `ignore(diag > 0.0)` 不是 assertion、PLR/IRM/IIVM/PLIV 的 `n_rep>1` 聚合不匹配 upstream `_aggregate_coefs_and_ses`、IRM/IIVM 空 conditional 训练 fold 静默填 0。
>
> 角色约束：verifier 是**只读**——它不能改项目文件、不能装包、不能 git write。每个 TODO 由对应的 producer 落地，每个 TODO 完成后回到 verifier 做一轮 verify。

---

## 派发路径

**宿主环境问题：** `mavis.cmd` 硬编码 `D:\Programs\MiniMax Code\resources\resources\daemon\cli.js`，但当前安装的 `D:\Programs\MiniMax Code\resources\app.asar`（430 MB）里**没有 `daemon/` 也没有任何 `mavis` 入口**——`asar list` 确认过。父 session 的 scratchpad 目录 `C:\Users\31379\.minimax\scratchpads\mvs_595a5c5ae8f04814b88de29e8462ec7b\` 也不存在。父 session 状态 `finished`。

**结论：** `mavis communication send` 这条路在当前机器上**不可用**。verifier 无法主动 push 派发；本文件就是 verifier 给父 session / 用户 / 任何后接手的人的"产出物"。让父 session 在下一次自检时通过 `mavis({command:"session messages", args:{session_id:"mvs_ca67c4c3aafa47798ffc4d08af01549a", limit:50}})` 拉 verifier transcript 也能拿到等效信息。

---

## TODO 列表（按依赖顺序）

### 阶段 1：CRITICAL（必须先清，否则下面所有都被掩盖）

| # | TODO | 负责 agent | 工作量 | 验证判据 |
|---|------|-----------|--------|---------|
| 1 | 新建 `check.mbt`，把全仓 ~80 处 `ignore(cond)` 全部替换成 `check(cond, "file:line: msg")` | `moonbit-coder` | 0.5 d | `moon test` 53 → 仍 53 pass；新增 4 个 should-panic 探针（matvec 错配、cholesky 非 SPD、unfitted coef、constructor 非法）全部 abort；`grep ignore(` 残留 0（除非单值丢弃） |
| 2 | IRM/IIVM 空 conditional 训练 fold：g0/g1/r0/r1 兜底改成 NaN，fit 收尾 `check(not has_nan, ...)` | `moonbit-coder` | 0.5 d | 新增 `test "irm_empty_d0_fold_aborts"` + `test "iivm_empty_z0_fold_aborts"` 触发 NaN → abort；现有 IRM/IIVM 测试仍 pass |
| 3 | 抽 `aggregator.mbt`，照搬 upstream `_aggregate_coefs_and_ses`，4 个 estimator 的 fit 改成"每轮存 (θ, SE)，最后聚合" | `moonbit-coder` | 1 d | `n_rep=1` 时与现在 byte-equal；`n_rep=5` 时与 `n_rep=1` 同 seed 差 ≤ 0.05（采样噪声） |

### 阶段 2：测试硬化

| # | TODO | 负责 agent | 工作量 | 验证判据 |
|---|------|-----------|--------|---------|
| 5 | 删 `plr_test.mbt:49` / `irm_test.mbt:44` / `pliv_test.mbt:78` / `iivm_test.mbt:64` / `did_test.mbt:61` 的 `ignore(se)`，加 `inspect(theta > 0.0)` + `inspect(se < 1.0)` + 把 PLR 容差从 `< 0.5` 收紧到 `< 0.2` | `moonbit-coder` | 0.5 d | `moon test` 仍 53 全 pass；容差收紧后无回归 |
| 6 | 新建 `assertion_test.mbt`，对每个 `check(cond, ...)` 站点写 should-panic 探针（至少覆盖每个 estimator 4 个关键 site） | `moonbit-coder` | 1 d | `moon test` 总数 ≥ 65 全 pass；`try? expr.is_err() == true` |

### 阶段 3：Python 对照 + 抽取

| # | TODO | 负责 agent | 工作量 | 验证判据 |
|---|------|-----------|--------|---------|
| 7 | 给 `validate_with_python.py` / `validate_irm_with_python.py` / `validate_iivm_with_python.py` / `validate_pliv_with_python.py` 各加 `n_rep=5` 对照段 | `coder` | 0.5 d | 4 个脚本跑完输出新 `n_rep=5` 行，差值 ≤ 0.05 |
| 10 | 抽 `var_est.mbt::var_est_linear(psi_a, psi_b) -> (theta, se)`，PLR/IRM/IIVM/PLIV 4 处调用 | `moonbit-coder` | 0.5 d | `moon test` 53 全 pass；coverage uncovered 行减少 ≥ 4 |

### 阶段 4：模型质量

| # | TODO | 负责 agent | 工作量 | 验证判据 |
|---|------|-----------|--------|---------|
| 4 | 新建 `logistic.mbt`，实现 Newton-IRLS 的 `LogisticRegression`，实现 `Learner` trait；给 IRM/IIVM 的 `ml_m`/`ml_r` 默认换成 Logistic | `moonbit-coder` | 1 d | IIVM end-to-end LATE 估计 CI 宽度从 ~0.7 缩到 < 0.5；`logistic_test.mbt` 全 pass |
| 8 | `seed_to_bytes` 从 3 个副本合并到 `kfold.mbt` 顶部 pub；改 full 32-bit little-endian | `moonbit-coder` | 0.1 d | `grep -rn "fn seed_to_bytes" dml-moonbit/` 剩 1 个；`seed=0` vs `seed=128` 产生不同 kfold（新增测试） |
| 9 | `matrix.mbt` 的 `mean` / `dot` / `matvec` / `matmul` 累积从 naive 改成 Kahan compensated sum | `moonbit-coder` | 0.5 d | `n=10^5` 全 `1e-10` 向量 `mean()` 相对误差 ≤ `1e-12` |

### 阶段 5：最终 verify

| # | TODO | 负责 agent | 验证判据 |
|---|------|-----------|---------|
| final | 全量回归 | `moonbit-verifier` | `moon test --target native` 65+ 全 pass；`moon build` 全目标（native / wasm-gc / js）成功；4 个 validate_*.py 跑过 n_rep=1 + n_rep=5；≥ 4 个对抗探针（非 SPD Cholesky、空 fold、维度错配、unfitted predict）；出 `dml-moonbit/_verify/final-verdict.md` PASS/FAIL |

---

## 责任分工

| Agent | TODO |
|---|---|
| `moonbit-coder` | #1, #2, #3, #4, #5, #6, #8, #9, #10 |
| `coder` | #7 |
| `moonbit-verifier`（本 session） | #final + 每个 TODO 完成后的 per-TODO verify |

## 跨 TODO 不变量

- 每完成一个 TODO，producer 必须自己先 `moon test` 全绿、跑新加的探针、跑 diff 静态读，然后才把 patch 推下来给 verifier
- verifier 对每个 TODO 跑 5 步：重跑 `moon test --target native`、重跑 `moon build`、读 diff、≥ 1 个对抗探针、出 `_verify/<todo-id>-verdict.md`
- 任何一步不过就把 patch 打回 producer
- 阶段 1 三个 TODO 全部 PASS 后才能开阶段 2；阶段 2 两个全 PASS 后才能开阶段 3
- 阶段 3 / 4 可以并行（独立）

## 估计总工作量

- 阶段 1：2 d
- 阶段 2：1.5 d
- 阶段 3：1 d（可与阶段 4 并行）
- 阶段 4：1.6 d
- 阶段 5：0.5 d
- 合计：~6.6 d（如果阶段 3 / 4 并行 ~5.5 d）

## 关于 verifier 怎么"用"这个清单

verifier 不在派发链路上——verifier 在每个 TODO 落地后被回调做验证。调用 verifier 的应该是：
1. 用户手动（最稳）：每个 TODO 完成后告诉 verifier "去 verify TODO #N"
2. 或者父 session 在收到 producer 的 "TODO #N done" 通知后，调用 `mavis({command:"session get", args:{...}})` 找到本 verifier session 并发新 prompt
3. 或者在 producer commit 时配一个 git hook 触发 verifier

verifier 不会主动轮询 producer 状态——它是被动验证方。
