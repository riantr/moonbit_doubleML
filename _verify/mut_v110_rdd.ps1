# v0.110.0 mutation harness for the RDD kernel / bandwidth gate.
#
# M1 point-estimate weights ignore the kernel   -> the `kernel` argument is
#                                               threaded to `rdd_design` but
#                                               discarded there
# M2 cluster-path weights ignore the kernel     -> `rdd_kernel_weights` keeps
#                                               its old inline `1 - |u|/h`, so
#                                               `coef` and `cluster_hac_se`
#                                               would be computed from two
#                                               different weight sets
# M3 bandwidth search minimises the MAXIMUM     -> argmin accidentally written
#                                               as argmax
# M4 criterion loses its b^4 variance term      -> the search still minimises
#                                               its own criterion, so only the
#                                               pilot identity sees it
# M5 Sigma^4 ignores nnmatch                    -> matching collapses to one
#                                               neighbour
#
# HISTORY ON M3, kept because it is the interesting one: until v0.113.0
# M3 was an EQUIVALENT MUTANT. `Sigma^4` was a pooled sum of squares, which
# made the criterion monotone increasing in `b`, so the true argmin WAS the
# first grid point -- and `best_mse` starting at 1e300 means an argmax keeps
# that same point. Argmin and argmax returned the same bandwidth, so the
# comparison direction was unobservable and the mutation was untestable.
#
# Switching `Sigma^4` to `rdrobust`'s nearest-neighbour matching (v0.113.0)
# changed the criterion's SHAPE: it no longer runs away monotonically in `b`,
# it has an interior minimum, and inverting the comparison now changes the
# answer. **Fixing the estimator to match upstream is also what made the
# search observable.** An equivalent mutant is a property of the criterion,
# not only of the code under mutation -- and it can be removed by changing
# the thing being measured rather than by strengthening the test.
#
# Each mutation must turn the suite red, and the suite must actually RUN (see
# the INCONCLUSIVE branch). UTF-8 without BOM; restore verified by SHA256
# against the backup, NOT against HEAD -- mid-release the working tree is
# supposed to differ from HEAD.
#
# KNOWN LIMITATION OF THIS GATE, recorded rather than hidden:
# `v110_optimal_bandwidth_minimises_its_criterion` checks that the returned
# bandwidth MINIMISES the published `bandwidth_mse`. It cannot check that
# `bandwidth_mse` IS Cattaneo's criterion -- mutating the criterion's `b^4`
# variance term leaves the search still minimising it, so the test stays green.
# Pinning the criterion to the paper's formula would mean recomputing xi(b) and
# sigma4 independently in the test, which needs `rdd_side`'s per-side residual
# arrays -- unequal lengths, so the pairing Cattaneo uses is a separate design
# decision (see `optimal_bandwidth`'s doc).

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$target = Join-Path $repo 'moonbit_doubleML\rdd.mbt'
$backup = Join-Path $repo '_verify\_bak_v110_rdd.mbt'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo

$mutations = @(
  @{ name = 'M1 point-estimate weights ignore the kernel'
     from  = "    w[k] = kernel.weight(u, h)"
     to    = "    w[k] = 1.0 - u.abs() / h   // MUT-M1" },

  @{ name = 'M2 cluster-path weights ignore the kernel'
     from  = "      weights.push(kernel.weight(u, h))"
     to    = "      weights.push(1.0 - u.abs() / h)   // MUT-M2" },

  @{ name = 'M3 bandwidth search minimises the MAXIMUM'
     from  = "    if mse < best_mse {"
     to    = "    if mse > best_mse {   // MUT-M3" },

  @{ name = 'M4 criterion loses its variance term'
     from  = "    bias * bias + b2 * b2 * sigma4 / n.to_double()"
     to    = "    bias * bias   // MUT-M4: b^4 variance term dropped" },

  @{ name = 'M5 Sigma^4 ignores nnmatch (matches with a single neighbour)'
     from  = "  let m = if nnmatch < n_r { nnmatch } else { n_r }"
     to    = "  let m = 1   // MUT-M5: nnmatch ignored" }
)

$survivors = @()
$equivalent = @()
$inconclusive = @()

foreach ($m in $mutations) {
  Copy-Item -LiteralPath $backup -Destination $target -Force
  $src = [System.IO.File]::ReadAllText($target, $enc)
  if ($src.IndexOf($m.from) -lt 0) {
    Write-Output ("SKIP    " + $m.name + "  -- anchor not found (rdd.mbt moved?)")
    Write-Output ''
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($target, $src, $enc)

  # Deliberately NOT --deny-warn. That flag is a CI policy, not an
  # assertion check, and using it here conflated two different failures a
  # third time: M1 and M2 leave their `kernel` parameter unused, which
  # --deny-warn turns into a build refusal, so the suite never ran and both
  # mutations were reported INCONCLUSIVE. The question this harness asks is
  # "do the ASSERTIONS catch it", and only a run of the assertions can
  # answer that. CI keeps --deny-warn on its own runs.
  $t = moon test --target native 2>&1 | Out-String
  $tCode = $LASTEXITCODE
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  tests exit={0}  {1}" -f $tCode, $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL: the suite did not run ***' }))

  # A suite with no total did not TEST anything; counting that as a kill is the
  # failure this harness exists to prevent.
  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  if (-not $testsRan) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the suite never ran"
    $inconclusive += $m.name
  } elseif ($testsRed) {
    Write-Output "  VERDICT KILLED"
  } else {
    # A mutant that survives is only acceptable when it is EQUIVALENT --
    # i.e. it cannot change behaviour on any input reachable through the
    # public API. Reporting it as "the gate is decorative" would be a
    # different and wrong claim, and reporting it as killed would be worse.
    if ($m.ContainsKey('equivalent') -and $m.equivalent) {
      Write-Output "  VERDICT SURVIVED (EXPECTED-EQUIVALENT)  <-- cannot fail on this DGP"
      $equivalent += $m.name
    } else {
      Write-Output "  VERDICT SURVIVED  <-- the gate is decorative"
      $survivors += $m.name
    }
  }
  Write-Output ''
}

Copy-Item -LiteralPath $backup -Destination $target -Force
$a = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$b = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
Write-Output ("restore rdd.mbt byte-identical to backup: " + ($a -eq $b))
$left = Select-String -Path $target -Pattern 'MUT-M\d' -ErrorAction SilentlyContinue
Write-Output ("mutation markers left: " + $(if ($left) { $left.Count } else { 0 }))

if ($survivors.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $survivors.Count + " mutation(s) SURVIVED non-equivalently.")
  exit 1
}
if ($equivalent.Count -gt 0) {
  Write-Output ("NOTE: " + $equivalent.Count + " mutation(s) survived as EQUIVALENT (see header).")
}
if ($inconclusive.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $inconclusive.Count + " mutation(s) INCONCLUSIVE.")
  exit 1
}
Write-Output ''
Write-Output 'RESULT: every non-equivalent mutation ran the suite and was killed. The RDD gate has teeth.'
exit 0
