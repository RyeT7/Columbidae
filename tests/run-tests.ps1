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
