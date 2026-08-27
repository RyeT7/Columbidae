<#
.SYNOPSIS
    Tests for lib\Lock.ps1 -- the overlap guard that keeps two scheduled ticks
    from deploying at once.
#>

function Test-Lock {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $lock = Join-Path $WorkDir 'deploy.lock'

    $a = Enter-DeployLock -Path $lock -StaleMinutes 30
    Assert-Equal $true  ($null -ne $a)          'lock acquired on a clean directory'
    Assert-Equal $true  (Test-Path $lock)       'lock file created'

    $b = Enter-DeployLock -Path $lock -StaleMinutes 30
    Assert-Equal $true  ($null -eq $b)          'concurrent run is refused the lock'

    # A refused run's finally must not delete the holder's lock file.
    Exit-DeployLock -Stream $b -Path $lock
    Assert-Equal $true  (Test-Path $lock)       'refused run does not delete the holder''s lock'

    Exit-DeployLock -Stream $a -Path $lock
    Assert-Equal $false (Test-Path $lock)       'holder releases and removes the lock'

    Set-Content -LiteralPath $lock -Value 'orphan'
    (Get-Item $lock).LastWriteTime = (Get-Date).AddMinutes(-60)
    $c = Enter-DeployLock -Path $lock -StaleMinutes 30
    Assert-Equal $true  ($null -ne $c)          'stale orphaned lock is broken'
    Exit-DeployLock -Stream $c -Path $lock

    Set-Content -LiteralPath $lock -Value 'orphan'
    (Get-Item $lock).LastWriteTime = (Get-Date).AddMinutes(-5)
    $d = Enter-DeployLock -Path $lock -StaleMinutes 30
    Assert-Equal $true  ($null -eq $d)          'recent orphaned lock is left alone'
}
