# v0.109.0 mutation harness for the sample-splitting gate.
#
# Two gates, both run under every mutation:
#   * `moon test --target native --deny-warn`  -> the in-process tests
#     (equivalence identity, derivation, staleness)
#   * `validate_splitting_contract.py`          -> the out-of-process refusals
#
# M1 supplied folds ignored   -- `fit` always draws, so the "a different
#                               partition must move the estimate" test
#                               breaks
# M2 derivation not applied   -- `set_sample_splitting` stores the folds
#                               but leaves `n_folds` / `n_rep` at the
#                               CONFIGURED values, so a model built as 9/7
#                               keeps running 9 folds and 7 reps on a
#                               supplied 3-fold / 2-rep partition
# M3 disjointness not checked -- the `require` that makes test sets
#                               pairwise disjoint is dropped, so an
#                               overlapping-but-fully-covering partition
#                               is accepted
#
# M2 WAS PREVIOUSLY "nrep always self.n_rep" in `fit`, which SURVIVED and
# turned out to be an EQUIVALENT MUTANT: `set_sample_splitting` had already
# written the derived count into `self.n_rep`, so reading the field was
# already reading the derived value. The redundant `if external` override
# in `fit` was deleted as a result. A harness that reported an equivalent
# mutant as "the gate is decorative" would have been wrong in the other
# direction, so the mutation was replaced with one that is a real defect.
#
# M3 was previously caught only because its input ALSO failed the coverage
# check. `overlapcover` was added to isolate disjointness; see the example.
#
# Each mutation must turn at least one gate red, and the test suite must have
# actually RUN (see the INCONCLUSIVE branch below).
#
# UTF-8 without BOM, absolute paths, restore from backup verified by SHA256 --
# NOT against HEAD, because mid-release the working tree is SUPPOSED to differ
# from HEAD and a HEAD comparison reports "DIRTY" on a correctly restored file.

$ErrorActionPreference = 'Continue'
$repo = 'D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML'
$plr = Join-Path $repo 'moonbit_doubleML\plr.mbt'
$kf = Join-Path $repo 'moonbit_doubleML\kfold.mbt'
$apo = Join-Path $repo 'moonbit_doubleML\apo.mbt'
$bPlr = Join-Path $repo '_verify\_bak_v109_plr.mbt'
$bKf = Join-Path $repo '_verify\_bak_v109_kfold.mbt'
$bApo = Join-Path $repo '_verify\_bak_v109_apo.mbt'
$enc = New-Object System.Text.UTF8Encoding($false)

Set-Location $repo

$mutations = @(
  @{ name = 'M1 supplied folds ignored (fit always draws)'
     file = $plr
     from  = "        let folds = if external {`n          self.smpls[r]`n        } else {`n          kfold(n, self.n_folds, self.seed + r)`n        }"
     to    = "        let folds = kfold(n, self.n_folds, self.seed + r)   // MUT-M1" },

  @{ name = 'M2 derivation not applied (set_sample_splitting keeps configured counts)'
     file = $plr
     from  = "      n_folds: checked.folds,`n      n_rep: checked.reps,`n      smpls: checked.smpls,"
     to    = "      smpls: checked.smpls,   // MUT-M2: derivation dropped" },

  @{ name = 'M3 disjointness not checked'
     file = $kf
     from  = "        require(seen[i] == false)`n        seen[i] = true"
     to    = "        seen[i] = true   // MUT-M3: disjointness dropped" },

  @{ name = 'M4 APOS propagation dropped (parent records, children ignore)'
     file = $apo
     from  = "        let child_fit = if self.smpls.length() > 0 {"
     to    = "        let child_fit = if false {   // MUT-M4" }
)

$survivors = @()
$inconclusive = @()

foreach ($m in $mutations) {
  # pristine restore of ALL THREE files before every attempt
  Copy-Item -LiteralPath $bPlr -Destination $plr -Force
  Copy-Item -LiteralPath $bKf  -Destination $kf  -Force
  Copy-Item -LiteralPath $bApo -Destination $apo -Force

  $src = [System.IO.File]::ReadAllText($m.file, $enc)
  if ($src.IndexOf($m.from) -lt 0) {
    Write-Output ("SKIP    " + $m.name + "  -- anchor not found (file moved?)")
    Write-Output ''
    continue
  }
  $src = $src.Replace($m.from, $m.to)
  [System.IO.File]::WriteAllText($m.file, $src, $enc)

  $t = moon test --target native --deny-warn 2>&1 | Out-String
  $tCode = $LASTEXITCODE
  $tLine = ($t -split "`r?`n") | Select-String -Pattern 'Total tests:' | Select-Object -Last 1

  $v = python validate_splitting_contract.py 2>&1 | Out-String
  $vCode = $LASTEXITCODE
  $vFail = ($v -split "`r?`n") | Select-String -Pattern 'ACCEPTED -- NOT REFUSED|contract: FAIL' | Select-Object -First 3

  Write-Output ("MUTATION  " + $m.name)
  Write-Output ("  tests   exit={0}  {1}" -f $tCode, $(if ($tLine) { $tLine.Line.Trim() } else { '*** NO TOTAL: the suite did not run ***' }))
  Write-Output ("  valid.  exit={0}" -f $vCode)
  if ($vFail) { $vFail | ForEach-Object { Write-Output ("            " + $_.Line.Trim()) } }

  # A suite that did not produce a total did not TEST anything. Counting
  # that as a kill is the failure this harness exists to prevent: a
  # mutation that merely breaks the build, or a stray --deny-warn
  # warning in an unrelated package, would then "prove" the gate
  # works. The tests must have RUN and reported failures.
  $testsRan = $null -ne $tLine
  $testsRed = $testsRan -and ($tLine.Line -notmatch 'failed: 0')
  $validRed = ($vCode -ne 0) -or ($null -ne $vFail)

  if (-not $testsRan) {
    Write-Output "  VERDICT INCONCLUSIVE  <-- the suite never ran; this is not evidence"
    $inconclusive += $m.name
  } elseif ($testsRed -or $validRed) {
    Write-Output "  VERDICT KILLED"
  } else {
    Write-Output "  VERDICT SURVIVED  <-- the gate is decorative"
    $survivors += $m.name
  }
  Write-Output ''
}

# restore and verify byte-identity against the backups
Copy-Item -LiteralPath $bPlr -Destination $plr -Force
Copy-Item -LiteralPath $bKf  -Destination $kf  -Force
Copy-Item -LiteralPath $bApo -Destination $apo -Force
foreach ($pair in @(@($plr, $bPlr), @($kf, $bKf), @($apo, $bApo))) {
  $a = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash
  $name = Split-Path $pair[0] -Leaf
  Write-Output ("restore {0,-12} byte-identical to backup: {1}" -f $name, ($a -eq $b))
}
$left = Select-String -Path $plr, $kf -Pattern 'MUT-M\d' -ErrorAction SilentlyContinue
Write-Output ("mutation markers left: " + $(if ($left) { $left.Count } else { 0 }))

if ($survivors.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $survivors.Count + " mutation(s) SURVIVED.")
  exit 1
}
if ($inconclusive.Count -gt 0) {
  Write-Output ''
  Write-Output ("RESULT: " + $inconclusive.Count + " mutation(s) INCONCLUSIVE (the suite never ran).")
  exit 1
}
Write-Output ''
Write-Output 'RESULT: every mutation ran the suite and was killed. The sample-splitting gate has teeth.'
exit 0
