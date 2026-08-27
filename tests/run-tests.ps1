<#
.SYNOPSIS
    Unit tests for the pure/local parts of the deploy pipeline.

.DESCRIPTION
    Covers config parsing, the overlap guard, and release pruning -- the logic
    that can be exercised without GitHub, IIS, or a running site. Everything
    happens in a temp folder; nothing here touches IIS or the network.

    Deliberately no Pester dependency: the only Pester on a stock Windows box
    is the ancient 3.x, and this project's whole ethos is not requiring module
    installs. Run it from a dev machine, not the deploy VM.

.EXAMPLE
    .\tests\run-tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libRoot  = Join-Path $repoRoot 'lib'

# The reason the code was split into lib\: these load directly, no AST tricks.
. (Join-Path $libRoot 'Logging.ps1')
. (Join-Path $libRoot 'Config.ps1')
. (Join-Path $libRoot 'Lock.ps1')
. (Join-Path $libRoot 'Releases.ps1')
# Iis.ps1 loads fine without IIS installed; only Resolve-IisPath is exercised
# here, since everything else in it touches the IIS:\ provider.
. (Join-Path $libRoot 'Iis.ps1')
. (Join-Path $libRoot 'Notify.ps1')

# Silence deploy logging; tests assert on behaviour, not log output.
function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory)][string] $Because)

    if ($Expected -eq $Actual) {
        $script:Passed++
        Write-Host "  PASS  $Because"
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Because" -ForegroundColor Red
        Write-Host "          expected: '$Expected'" -ForegroundColor Red
        Write-Host "          actual:   '$Actual'" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock] $Action, [Parameter(Mandatory)][string] $Because)

    try {
        & $Action | Out-Null
        $script:Failed++
        Write-Host "  FAIL  $Because (no exception thrown)" -ForegroundColor Red
    } catch {
        $script:Passed++
        Write-Host "  PASS  $Because"
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "deploy-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Write-Host "`nConfig parsing"
    # Covers the cases the hand-rolled parser has to get right: Windows paths
    # and URLs (embedded colons), comments, quotes, and blank values.
    $configFile = Join-Path $work 'test.yaml'
    @(
        '# a comment line'
        ''
        'github_owner: acme'
        'deploy_root: C:\inetpub\deployments\app'
        'health_url: http://localhost:8080/health'
        'quoted: "spaced value"'
        'single: ''sq value'''
        'trailing: value   # inline comment'
        'hash_in_value: pa#ssword'
        'blank_value:'
        'keep_releases: 7'
        'not_a_number: abc'
        'no_colon_line_ignored'
    ) | Set-Content -LiteralPath $configFile -Encoding UTF8

    $cfg = Read-FlatConfig -Path $configFile
    Assert-Equal 'acme'                             $cfg['github_owner']  'plain value'
    Assert-Equal 'C:\inetpub\deployments\app'       $cfg['deploy_root']   'Windows path keeps its drive colon'
    Assert-Equal 'http://localhost:8080/health'     $cfg['health_url']    'URL keeps scheme and port colons'
    Assert-Equal 'spaced value'                     $cfg['quoted']        'double quotes stripped'
    Assert-Equal 'sq value'                         $cfg['single']        'single quotes stripped'
    Assert-Equal 'value'                            $cfg['trailing']      'inline comment stripped'
    Assert-Equal 'pa#ssword'                        $cfg['hash_in_value'] '# without leading space is kept'
    Assert-Equal ''                                 $cfg['blank_value']   'blank value parses as empty'
    Assert-Equal $false                             $cfg.ContainsKey('no_colon_line_ignored') 'line without colon ignored'

    Assert-Equal 'acme'    (Get-ConfigValue -Config $cfg -Key 'github_owner' -Required) 'required value returned'
    Assert-Equal 'fallback' (Get-ConfigValue -Config $cfg -Key 'absent' -Default 'fallback') 'default used for absent key'
    Assert-Equal 'fallback' (Get-ConfigValue -Config $cfg -Key 'blank_value' -Default 'fallback') 'default used for blank value'
    Assert-Equal 7  (Get-ConfigInt -Config $cfg -Key 'keep_releases' -Default 5) 'int parsed'
    Assert-Equal 42 (Get-ConfigInt -Config $cfg -Key 'absent' -Default 42) 'int default used'

    Assert-Throws { Get-ConfigValue -Config $cfg -Key 'blank_value' -Required } 'required-but-blank throws'
    Assert-Throws { Get-ConfigInt -Config $cfg -Key 'not_a_number' -Default 1 } 'non-numeric int throws'
    Assert-Throws { Read-FlatConfig -Path (Join-Path $work 'nope.yaml') }       'missing config file throws'

    Write-Host "`nOverlap guard"
    $lock = Join-Path $work 'deploy.lock'

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
    Remove-Item $lock -Force

    Write-Host "`nIIS path resolution"
    # A frontend at "/" and a backend at "/api" under one site must resolve to
    # different provider paths, or the two configs would fight over one target.
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site')                'site root when AppPath omitted'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '/')   'site root for "/"'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '')    'site root for empty string'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '  ')  'site root for whitespace'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '/api')   'leading slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath 'api')    'no leading slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '/api/')  'trailing slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '\api')   'backslash accepted'
    Assert-Equal 'IIS:\Sites\My Site\api\v1'  (Resolve-IisPath -SiteName 'My Site' -AppPath '/api/v1') 'nested application'
    Assert-Equal $true ((Resolve-IisPath -SiteName 'S' -AppPath '/') -ne (Resolve-IisPath -SiteName 'S' -AppPath '/api')) 'root and sub-app differ'
    Assert-Throws { Resolve-IisPath -SiteName '' -AppPath '/api' } 'empty site name throws'

    Write-Host "`nNotification payload"
    # This schema is a published contract -- consumers parse these field names,
    # so renaming or dropping one is a breaking change. These assertions exist
    # to make that break loud rather than silent.
    $obj = (New-NotificationPayload -Status 'error' -Message 'Boom.' -Tag 'deploy-xyz' -Target 'S/api') | ConvertFrom-Json
    Assert-Equal 'error'      $obj.status                          'status field'
    Assert-Equal 'deploy-xyz' $obj.tag                             'tag field'
    Assert-Equal 'S/api'      $obj.target                          'target field'
    Assert-Equal 'Boom.'      $obj.message                         'message field'
    Assert-Equal $env:COMPUTERNAME $obj.host                       'host field identifies the deploy target'
    Assert-Equal $true ($obj.timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') 'timestamp is ISO 8601 UTC'

    $expected = @('status', 'tag', 'target', 'message', 'host', 'timestamp') | Sort-Object
    $actual   = $obj.PSObject.Properties.Name | Sort-Object
    Assert-Equal ($expected -join ',') ($actual -join ',')         'schema has exactly the documented fields'

    # Optional fields absent early in a run must still serialise, not vanish.
    $partial = (New-NotificationPayload -Status 'error' -Message 'Failed before the release was known.') | ConvertFrom-Json
    Assert-Equal '' $partial.tag                                   'empty tag serialises as empty string'
    Assert-Equal '' $partial.target                                'empty target serialises as empty string'

    foreach ($status in 'success', 'rolled-back', 'rollback-failed', 'error') {
        $s = (New-NotificationPayload -Status $status -Message 'm') | ConvertFrom-Json
        Assert-Equal $status $s.status                             "status '$status' round-trips"
    }

    Assert-Throws { New-NotificationPayload -Status 'maybe' -Message 'm' }     'unknown status rejected'

    Write-Host "`nNotification failure isolation"
    # The property the whole design depends on: a broken webhook must never
    # throw into the deploy path. Port 9 refuses instantly; no traffic leaves.
    $threw = $false
    try {
        Send-DeployNotification -Url 'http://127.0.0.1:9/' -Status 'success' `
            -Message 'unreachable endpoint' -TimeoutSeconds 2
    } catch { $threw = $true }
    Assert-Equal $false $threw 'unreachable webhook does not throw'

    $threw = $false
    try { Send-DeployNotification -Url '' -Status 'success' -Message 'disabled' } catch { $threw = $true }
    Assert-Equal $false $threw 'blank url is a silent no-op'

    # Must emit nothing to the pipeline, or callers' return values get polluted.
    $emitted = Send-DeployNotification -Url '' -Status 'success' -Message 'quiet'
    Assert-Equal $true ($null -eq $emitted) 'send emits nothing to the pipeline'

    Write-Host "`nSource encoding"
    # PS 5.1 reads BOM-less .ps1 files as ANSI, so a stray non-ASCII character
    # in source gets silently mangled on the deploy target.
    $nonAscii = @()
    Get-ChildItem -Path $repoRoot -Recurse -Filter *.ps1 | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName)
        if ($content -cmatch '[^\x00-\x7F]') { $nonAscii += $_.Name }
    }
    Assert-Equal '' ($nonAscii -join ',') 'all .ps1 files are pure ASCII'

    Write-Host "`nLog rotation"
    # The guarantee being tested is a hard ceiling on bytes: on a storage-
    # sensitive host the log must never grow without limit.
    $logDir = Join-Path $work 'logs'
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
    try { Invoke-LogRotation -Path (Join-Path $work 'no\such\dir\x.log') -MaxBytes 1 -Keep 2 } catch { $threw = $true }
    Assert-Equal $false $threw 'rotation failure never throws into the deploy path'

    # Write-Log itself must respect the cap end to end.
    Get-ChildItem -Path $logDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-Log -ErrorAction SilentlyContinue
    . (Join-Path $libRoot 'Logging.ps1')
    $script:LogFile     = $logPath
    $script:LogMaxBytes = 2000
    $script:LogKeep     = 2
    # 6>$null swallows Write-Host's information stream so 200 lines of deploy
    # log don't drown the test output.
    1..200 | ForEach-Object { Write-Log "line $_ padded out to make the file grow reasonably quickly" } 6>$null
    $active = (Get-Item $logPath).Length
    Assert-Equal $true ($active -lt 2000 + 200) 'Write-Log keeps the active log near the cap'
    $all = @(Get-ChildItem -Path $logDir -Filter 'deploy.log*')
    Assert-Equal $true ($all.Count -le 3) 'Write-Log keeps at most Keep+1 files'
    $script:LogFile = $null
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    Write-Host "`nRelease pruning"
    $pruneRoot = Join-Path $work 'releases'
    New-Item -ItemType Directory -Path $pruneRoot -Force | Out-Null
    for ($i = 1; $i -le 8; $i++) {
        $d = New-Item -ItemType Directory -Path (Join-Path $pruneRoot ("release-{0:d2}" -f $i)) -Force
        $d.CreationTime = (Get-Date).AddMinutes(-100 + $i)   # release-08 is newest
    }
    New-Item -ItemType Directory -Path (Join-Path $pruneRoot 'not-a-release') -Force | Out-Null

    Remove-OldReleases -DeployRoot $pruneRoot -Keep 3 -Protected @(
        (Join-Path $pruneRoot 'release-08'),
        (Join-Path $pruneRoot 'release-01')
    )

    $remaining = (Get-ChildItem $pruneRoot -Directory | Sort-Object Name | ForEach-Object Name) -join ','
    Assert-Equal 'not-a-release,release-01,release-06,release-07,release-08' $remaining `
        'keeps 3 newest, honours protected list, ignores non-release folders'

    $before = (Get-ChildItem $pruneRoot -Directory).Count
    Remove-OldReleases -DeployRoot $pruneRoot -Keep 10 -Protected @()
    Assert-Equal $before (Get-ChildItem $pruneRoot -Directory).Count 'no pruning when under the keep threshold'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$($script:Passed) passed, $($script:Failed) failed`n"
if ($script:Failed -gt 0) { exit 1 }
exit 0
