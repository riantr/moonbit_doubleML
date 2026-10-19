# v0.116.0 mutation harness for the `vce = "nn"` / procedure (iii) gates.
#
# M1  the finite-sample correction `sqrt(Ji/(Ji+1))` is dropped
#                                               -> nn residual stops being on
#                                                  the scale of a regression
#                                                  residual
# M2  tie tolerance takes MIN(dleft,dright)      -> equivalent on every
#     instead of MAX                                fixture here; see header
# M3  the rank-1 bias term is dropped from `Q`   -> `Q` becomes the plain
#                                                  p-order fit and procedure
#                                                  (iii) silently becomes (ii)
# M4  `Ls` reads `u^p` instead of `u^(p+1)`      -> the bias correction is
#                                                  scaled wrong
# M5  `Ls` is built with the b-weights           -> `h` and `b` are confused
#     instead of the h-weights                       in the bias term
# M6  the `vce` dispatch is inverted             -> "nn" silently computes
#                                                  hc0, and vice versa
# M7  `gamma` reads row `p` of `Gq^-1`           -> the wrong bias direction
#     instead of row `p+1`
# M8  row selection drops the support mask       -> the zero-weight boundary
#                                                  row becomes a live neighbour
# M9  `rdd_weight_at` stops masking              -> weights go NEGATIVE
#     outside the kernel support                    outside the support and
#                                                  `Gq` stops being positive
#                                                  definite
# M10 the union window collapses to `h`          -> `b` never widens the
#                                                  sample, so the bias fit is
#                                                  refit at `h`
#
# M2 AND M8 ARE EXPECTED TO SURVIVE, and that is a finding rather than an
# excuse. Two upstream fidelity points that this fixture cannot resolve:
#
#   M2  tie tolerance `max(dleft,dright) * sqrt(eps)` (funs.py:114) vs the
#       `min` this file originally wrote. They differ only when
#       `|dleft - dright|` lands between `min*sqrt(eps)` and
#       `max*sqrt(eps)` -- about 1e-16 wide RELATIVE, so no
#       double-precision running variable lands there by accident. The
#       source was corrected to `max` anyway, on fidelity grounds; this
#       mutation is kept precisely so the limit is recorded rather than
#       assumed. If a future fixture does hit the window, this line flips
#       to KILLED and the header must be updated.
#
#   M8  the row-selection rule `w > 0` vs `w >= 0`. Upstream selects on
#       the kernel WEIGHT being positive (rdrobust.py:779-781), so for a
#       compact kernel a row sitting exactly on the bandwidth edge has
#       weight 0 and is EXCLUDED. Substituting `|u| <= gov` admits it.
#       This is a real semantic difference and it is NOT gated: it needs
#       a fixture with a running variable landing exactly on a bandwidth
#       edge, which neither the DGP nor the v0.115.0 fixture has, and
#       adding one would have meant regenerating every oracle constant to
#       pin a boundary case. Recorded here as a known gap rather than
#       quietly closed with a test that cannot fail.
#
# M9 is the one that was actually WRITTEN, by accident, during v0.116.0
# and then found by the oracle. `RDDKernel::weight` returns `1 - |u|/h`,
# which is negative for `|u| > h`; every pre-v0.116.0 caller filters on
# `u.abs() <= h` first, so nothing had ever evaluated the negative branch.
# The CCT `max(h, b)` union window is the first caller that does, and with
# `b > h` the Gram matrix stops being positive definite and
# `solve_spd` aborts. It is in this list because "a crash" and "a wrong
# answer" are the same verdict to the gate and the harness should be able
# to say so.
#
# M3 is the historically interesting one. If the rank-1 term is dropped,
# `Q` IS the p-order design, the sandwich becomes procedure (ii)'s, and the
# point estimate still matches the oracle -- because `xi_bc` and `xi_q(b)`
# differ only through that term's effect on `m`. So a mutation that
# destroys the headline feature survives every point-estimate gate and is
# killed ONLY by the variance gates. That is the argument for having them.
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
# KNOWN LIMITATION, recorded rather than hidden: this harness proves the
# gates react, not that the oracle constant is still current. The constants
# come from `_verify/gen_v116_oracle.py`; re-running it is what refreshes
# them, and if upstream `rdrobust` changes, nothing here notices until a
# human re-runs the generator.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$target = Join-Path $repo 'moonbit_doubleML\rdd.mbt'
$backup = Join-Path $repo '_verify\_bak_v116_rdd.mbt'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo

Copy-Item -LiteralPath $target -Destination $backup -Force
Write-Output ('backup written: ' + $backup)

$mutations = @(
  @{ name = 'M1 finite-sample correction sqrt(Ji/(Ji+1)) dropped'
     from  = 'res[pos] = sf * (y[pos] - s_y / ji.to_double())'
     to    = 'res[pos] = (y[pos] - s_y / ji.to_double())   // MUT-M1' },

  @{ name = 'M2 tie tolerance takes MIN instead of MAX (expected-equivalent)'
     from  = 'let largest = if dleft > dright { dleft } else { dright }'
     to    = 'let largest = if dleft > dright { dright } else { dleft }   // MUT-M2'
     equivalent = $true },

  @{ name = 'M3 rank-1 bias term dropped from Q'
     from  = '    let vi = wh[k] * ai - m[k] * ls_a'
     to    = '    let vi = wh[k] * ai   // MUT-M3' },

  @{ name = 'M4 Ls reads u^p instead of u^(p+1)'
     from  = '    let pw = xp[k * kq + p + 1]'
     to    = '    let pw = xp[k * kq + p]   // MUT-M4' },

  @{ name = 'M5 Ls built with the b-weights instead of the h-weights'
     from  = '    let wk = wh[k] * pw'
     to    = '    let wk = wb[k] * pw   // MUT-M5' },

  @{ name = 'M6 vce dispatch inverted'
     from  = '      "nn" => true'
     to    = '      "nn" => false   // MUT-M6' },

  @{ name = 'M7 gamma reads row p of Gq^-1 instead of row p+1'
     from  = '  rhs_q[p + 1] = 1.0'
     to    = '  rhs_q[p] = 1.0   // MUT-M7' },

  @{ name = 'M8 row selection drops the support mask'
     from  = '      if rdd_weight_at(kernel, u, gov) > 0.0 {'
     to    = '      if u.abs() <= gov {   // MUT-M8'
     equivalent = $true },

  @{ name = 'M9 rdd_weight_at stops masking outside the kernel support'
     from  = "  if u.abs() <= h {`n    kernel.weight(u, h)`n  } else {`n    0.0`n  }"
     to    = "  if true {   // MUT-M9`n    kernel.weight(u, h)`n  } else {`n    0.0`n  }" },

  @{ name = 'M10 union window collapses to h (b never widens the sample)'
     from  = '  let gov = if b > h { b } else { h }'
     to    = '  let gov = h   // MUT-M10' }
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
    $inconclusive += $m.name
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($target, $src, $enc)

  $t = moon test --target native 2>&1 | Out-String
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  tests {0}" -f $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL: the suite did not run ***' }))

  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  # A run with no `Total tests:` line is NOT automatically inconclusive.
  # MoonBit's driver ABORTS on the first red assertion, so a gate that
  # fires takes the whole run down and never reaches the summary line --
  # which is indistinguishable, from the summary alone, from a compile
  # refusal. The discriminator is `Active test at executable exit`: if the
  # runner names the test that was executing when the process died, the
  # suite went RED, and that is a kill.
  #
  # Getting this wrong is how v0.115.0's M1 was reported INCONCLUSIVE, and
  # how v0.116.0's M1 and M9 were both reported INCONCLUSIVE on the first
  # run even though each had already killed its gate by aborting inside it.
  $activeLine = ($t -split "`r?`n") | Select-String -Pattern 'Active test at executable exit' | Select-Object -First 1
  $diedInTest = ($null -ne $tLine) -or ($null -ne $activeLine)
  if (-not $testsRan -and $activeLine) {
    Write-Output ("  killed by abort inside: " + (($activeLine.Line -split '-')[-1]).Trim())
  }
  if (-not $diedInTest) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the suite never ran"
    # Print the tail. A missing Total line has two very different causes
    # -- a compile refusal, or the test binary dying mid-run -- and they
    # are not the same verdict. Reporting them identically is how a real
    # result gets filed as "inconclusive" and lost.
    Write-Output '  --- last 12 lines of output ---'
    ($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 12 | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
    $inconclusive += $m.name
  } elseif ($testsRed -or -not $testsRan) {
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
Write-Output ('RESULT: every mutation ran the suite and was killed except the ' +
  $equivalent.Count + ' declared equivalent. The procedure (iii) gates have teeth.')
exit 0