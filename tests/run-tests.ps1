<#
.SYNOPSIS
    Runs the unit tests for the pure/local parts of the deploy pipeline.

.DESCRIPTION
    Wiring and reporting only. The assertions live in tests\cases\, one file
    per lib concern, and the assertion helpers in tests\TestFramework.ps1.

    Together they cover the logic that can be exercised without GitHub, IIS, or
    a running site. Everything happens in a temp folder; nothing here touches
    IIS or the network. Run it from a dev machine, not the deploy VM.

    The contract every case file follows:

      - it is named <Concern>.Tests.ps1 and defines exactly one function named
        Test-<Concern> -- Config.Tests.ps1 defines Test-Config;
      - that function takes -WorkDir (a private temp folder, deleted for it
        afterwards) and -RepoRoot, and takes both whether it uses them or not;
      - loading the file defines that function and does nothing else, so the
        runner controls when and in what state each case runs.

    Cases are isolated from each other in both directions: each gets its own
    workspace, and one that throws is recorded as a failure without costing the
    results of every case queued behind it.

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
# Loaded here rather than inside each case so the libs are wired up the same
# way deploy-poll-lite.ps1 wires them, once, for every case.
. (Join-Path $libRoot 'Logging.ps1')
. (Join-Path $libRoot 'Config.ps1')
. (Join-Path $libRoot 'Lock.ps1')
. (Join-Path $libRoot 'Releases.ps1')
# Iis.ps1 loads fine without IIS installed; only Resolve-IisPath is exercised
# here, since everything else in it touches the IIS:\ provider.
. (Join-Path $libRoot 'Iis.ps1')
. (Join-Path $libRoot 'Notify.ps1')

. (Join-Path $PSScriptRoot 'TestFramework.ps1')

# Silence deploy logging; tests assert on behaviour, not log output. Defined
# after the libs so it shadows the real Write-Log. Logging.Tests.ps1 gets the
# real one back for itself by dot-sourcing Logging.ps1 in its own scope.
function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

$caseRoot = Join-Path $PSScriptRoot 'cases'
$cases = @(Get-ChildItem -Path $caseRoot -Filter '*.Tests.ps1' | Sort-Object Name)
if ($cases.Count -eq 0) { throw "No test cases found in $caseRoot" }

foreach ($case in $cases) { . $case.FullName }

foreach ($case in $cases) {
    $name = $case.Name -replace '\.Tests\.ps1$', ''
    $fn   = "Test-$name"

    # A case file that defines nothing the runner can call must fail the run,
    # not be skipped quietly: a suite that silently stops covering something is
    # worse than one that was never written.
    if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "`n$name"
        Add-TestFailure "$($case.Name) defines no $fn function"
        continue
    }

    Write-Host "`n$name"
    $work = New-TestWorkspace -Name $name
    try {
        & $fn -WorkDir $work -RepoRoot $repoRoot
    } catch {
        Add-TestFailure "$name threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n$($script:Passed) passed, $($script:Failed) failed`n"
if ($script:Failed -gt 0) { exit 1 }
exit 0
