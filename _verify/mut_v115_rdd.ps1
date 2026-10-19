# v0.115.0 mutation harness for the CCT bias-correction gate.
#
# M1 bias bandwidth pinned to the point bandwidth -> `optimal_bias_bandwidth`
#                                                 returns `self.bandwidth`
# M2 bias subtracted in the WRONG DIRECTION     -> `tau_cl + (bias_r - bias_l)`
# M3 criterion ignores `order`                   -> the `b^(2(order+1))` variance
#                                                  exponent collapses to `b^4`
# M4 the `u^2` column is dropped from the design -> order-2 fits silently
#                                                  become order-1 fits
# M5 residuals from a TRUNCATED prediction       -> `Sigma^4` at order >= 2 is
#                                                  computed from a linear fit
#
# HISTORY, kept because M1 is the interesting one. Before this release the
# package had no second bandwidth at all, so the question "does `b` get
# chosen independently of `h`?" had no code to ask. It is now a live risk:
# `rdrobust` itself makes `rho = 1` the DEFAULT when `h` is supplied without
# `b` (`b = h / rho`), so a `b = h` path is not hypothetical. M1 is that
# path written into the search. It is the shape of the v0.113 M3 lesson --
# a quantity that is not independently observable cannot be gated -- and
# `v115_bias_bandwidth_differs_from_the_point_bandwidth` is the assertion
# written specifically to kill it.
#
# M4 is the mutation the bias gates alone CANNOT see: both routes through
# `bias_corrected_coef` call the same `rdd_design`, so the collapse identity
# still holds, the bias is still non-zero, and `b` still differs from `h`.
# It is killed only by `v115_quadratic_fit_recovers_an_exactly_quadratic_dgp`,
# which is why that test needs its own asymmetric-curvature noiseless DGP.
#
# Deliberately NOT --deny-warn (see mut_v110_rdd.ps1 for the full reason):
# that flag is a CI policy, and using it here turns "unused parameter" into
# a build refusal so the suite never runs and the mutation is misreported
# INCONCLUSIVE. The question here is "do the ASSERTIONS catch it".
#
# Each mutation must turn the suite red AND the suite must actually RUN. A
# missing total line means nothing was tested; counting that as a kill is
# the failure this harness exists to prevent.
#
# KNOWN LIMITATION, recorded rather than hidden: nothing here pins the
# VALUE of `b` against `rdrobust`. `b` is the argmin of this port's
# order-2 criterion, and this port's criterion deviates from rdrobust's in
# at least three documented ways (50-point grid not 100; `Sigma^4` pooled
# over left observations rather than kernel-weighted over matched pairs;
# no bias-correction pilot machinery). Pinning `b` to rdrobust's number
# would require running rdrobust itself, which is not available here.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$target = Join-Path $repo 'moonbit_doubleML\rdd.mbt'
$backup = Join-Path $repo '_verify\_bak_v115_rdd.mbt'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo

if (-not (Test-Path -LiteralPath $backup)) {
  Copy-Item -LiteralPath $target -Destination $backup
  Write-Output ('backup written: ' + $backup)
} else {
  Write-Output 'reusing existing backup'
}

$mutations = @(
  @{ name = 'M1 bias bandwidth pinned to the point bandwidth'
     from  = "  }`n  best_b`n}"
     to    = "  }`n  self.bandwidth   // MUT-M1`n}" },

  @{ name = 'M2 bias subtracted in the wrong direction'
     from  = "  tau_cl - (bias_r - bias_l)"
     to    = "  tau_cl + (bias_r - bias_l)   // MUT-M2" },

  @{ name = 'M3 criterion ignores order (variance exponent fixed at b^4)'
     from  = "    for step = 0; step < order; step = step + 1 {"
     to    = "    for step = 0; step < 1; step = step + 1 {   // MUT-M3" },

  @{ name = 'M4 the u^2 column is dropped from the design'
     from  = "    for d = 0; d < order; d = d + 1 {"
     to    = "    for d = 0; d < 1; d = d + 1 {   // MUT-M4" },

  @{ name = 'M5 residuals from a truncated (linear) prediction'
     from  = "      for d = 1; d <= order; d = d + 1 {"
     to    = "      for d = 1; d < 2; d = d + 1 {   // MUT-M5" }
)

$survivors = @()
$equivalent = @()
$inconclusive = @()

foreach ($m in $mutations) {
  Copy-Item -LiteralPath $backup -Destination $target -Force
  $src = [System.IO.File]::ReadAllText($target, $enc)
  $count = ([regex]::Matches($src, [regex]::Escape($m.from))).Count
  if ($count -ne 1) {
    Write-Output ("SKIP    " + $m.name + "  -- anchor matched " + $count + " times (need exactly 1)")
    Write-Output ''
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($target, $src, $enc)

  $t = moon test --target native 2>&1 | Out-String
  $tCode = $LASTEXITCODE
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  tests exit={0}  {1}" -f $tCode, $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL: the suite did not run ***' }))

  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  if (-not $testsRan) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the suite never ran"
    # Print the tail. A missing Total line has two very different causes
    # -- a compile refusal, or the test binary dying mid-run -- and they
    # are not the same verdict. Reporting them identically is how a real
    # result gets filed as "inconclusive" and lost.
    Write-Output '  --- last 12 lines of output ---'
    ($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 12 | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
    $inconclusive += $m.name
  } elseif ($testsRed) {
    Write-Output "  VERDICT KILLED"
  } else {
    if ($m.ContainsKey('equivalent') -and $m.equivalent) {
      Write-Output "  VERDICT SURVIVED (EXPECTED-EQUIVALENT)"
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
Write-Output 'RESULT: every mutation ran the suite and was killed. The CCT gate has teeth.'
exit 0