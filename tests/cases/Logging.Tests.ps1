<#
.SYNOPSIS
    Tests for lib\Logging.ps1 -- size-based rotation and the on-disk ceiling.

.DESCRIPTION
    The runner stubs out Write-Log so the other cases stay quiet. This case
    needs the real one, so it dot-sources Logging.ps1 into its own function
    scope: the real Write-Log and Invoke-LogRotation shadow the stub for the
    duration of the call and vanish when it returns, leaving the stub intact
    for every case that runs after it.
#>

function Test-Logging {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    . (Join-Path (Join-Path $RepoRoot 'lib') 'Logging.ps1')

    # The guarantee being tested is a hard ceiling on bytes: on a storage-
    # sensitive host the log must never grow without limit.
    $logDir = Join-Path $WorkDir 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath = Join-Path $logDir 'deploy.log'

    function New-LogOfSize {
        param([string] $Path, [int] $Bytes)
        [System.IO.File]::WriteAllText($Path, ('x' * $Bytes))
    }

    # Under the cap: nothing moves.
    New-LogOfSize -Path $logPath -Bytes 100
    Invoke-LogRotation -Path $logPath -MaxBytes 1000 -Keep 3
    Assert-Equal $true  (Test-Path $logPath)        'under cap: log left in place'
    Assert-Equal $false (Test-Path "$logPath.1")    'under cap: no archive created'

    # Over the cap: current log becomes .1 and a fresh one starts.
    New-LogOfSize -Path $logPath -Bytes 2000
    Invoke-LogRotation -Path $logPath -MaxBytes 1000 -Keep 3
    Assert-Equal $false (Test-Path $logPath)        'over cap: active log rotated away'
    Assert-Equal $true  (Test-Path "$logPath.1")    'over cap: archive .1 created'

    # Repeated rotations shuffle archives up and cap the total count.
    # Files enter rotation at just over the cap, which is what Write-Log
    # produces: it checks the size before every append, so a log crosses the
    # threshold by at most one line.
    for ($i = 0; $i -lt 5; $i++) {
        New-LogOfSize -Path $logPath -Bytes 1001
        Invoke-LogRotation -Path $logPath -MaxBytes 1000 -Keep 3
    }
    $archives = @(Get-ChildItem -Path $logDir -Filter 'deploy.log.*')
    Assert-Equal 3 $archives.Count                  'archive count never exceeds Keep'
    Assert-Equal $false (Test-Path "$logPath.4")    'no archive beyond Keep survives'

    # The ceiling the config promises: (Keep + 1) * MaxBytes, with a one-line
    # tolerance per file since rotation triggers on crossing, not before.
    New-LogOfSize -Path $logPath -Bytes 900
    $totalBytes = (Get-ChildItem -Path $logDir -File | Measure-Object -Property Length -Sum).Sum
    $ceiling = (3 + 1) * 1000 + (3 + 1) * 200   # 200B/line tolerance
    Assert-Equal $true ($totalBytes -le $ceiling) 'total on disk stays within the documented ceiling'

    # An oversized log dropped in by hand (or left behind after log_max_size_mb
    # is lowered) is archived whole rather than truncated -- the ceiling is
    # exceeded until it cycles out, and that is the intended trade.
    Get-ChildItem -Path $logDir -File | Remove-Item -Force
    New-LogOfSize -Path $logPath -Bytes 100000
    Invoke-LogRotation -Path $logPath -MaxBytes 1000 -Keep 3
    Assert-Equal 100000 (Get-Item "$logPath.1").Length 'oversized log is preserved, not truncated'

    # MaxBytes 0 disables rotation entirely.
    Get-ChildItem -Path $logDir -File | Remove-Item -Force
    New-LogOfSize -Path $logPath -Bytes 50000
    Invoke-LogRotation -Path $logPath -MaxBytes 0 -Keep 3
    Assert-Equal $true  (Test-Path $logPath)        'MaxBytes 0 disables rotation'
    Assert-Equal $false (Test-Path "$logPath.1")    'MaxBytes 0 creates no archive'

    # Missing log, and an unwritable path, must both be non-events.
    Get-ChildItem -Path $logDir -File | Remove-Item -Force
    $threw = $false
    try { Invoke-LogRotation -Path $logPath -MaxBytes 1000 -Keep 3 } catch { $threw = $true }
    Assert-Equal $false $threw 'rotating a non-existent log does not throw'

    $threw = $false
    try { Invoke-LogRotation -Path (Join-Path $WorkDir 'no\such\dir\x.log') -MaxBytes 1 -Keep 2 } catch { $threw = $true }
    Assert-Equal $false $threw 'rotation failure never throws into the deploy path'

    Write-Host "  Write-Log end to end"
    # Write-Log itself must respect the cap end to end.
    Get-ChildItem -Path $logDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:LogFile     = $logPath
    $script:LogMaxBytes = 2000
    $script:LogKeep     = 2
    try {
        # 6>$null swallows Write-Host's information stream so 200 lines of deploy
        # log don't drown the test output.
        1..200 | ForEach-Object { Write-Log "line $_ padded out to make the file grow reasonably quickly" } 6>$null
        $active = (Get-Item $logPath).Length
        Assert-Equal $true ($active -lt 2000 + 200) 'Write-Log keeps the active log near the cap'
        $all = @(Get-ChildItem -Path $logDir -Filter 'deploy.log*')
        Assert-Equal $true ($all.Count -le 3) 'Write-Log keeps at most Keep+1 files'
    } finally {
        # $script: resolves to the runner, not to this function, so the log file
        # has to be unset by hand or later cases would write into a deleted temp
        # folder.
        $script:LogFile = $null
    }
}
