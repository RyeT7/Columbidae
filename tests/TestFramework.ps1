<#
.SYNOPSIS
    Assertion helpers and the shared pass/fail tally for the test suite.

.DESCRIPTION
    Dot-sourced by run-tests.ps1 before any case file, so the counters below
    live in the runner's script scope and every case accumulates into one
    tally no matter which file its assertions are written in.

    Deliberately no Pester dependency: the only Pester on a stock Windows box
    is the ancient 3.x, and this project's whole ethos is not requiring module
    installs.
#>

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

function Add-TestFailure {
    <#
    .SYNOPSIS
        Records a failure that is not an assertion -- a case that threw, or one
        the runner could not invoke at all.
    #>
    param([Parameter(Mandatory)][string] $Because)

    $script:Failed++
    Write-Host "  FAIL  $Because" -ForegroundColor Red
}

function New-TestWorkspace {
    <#
    .SYNOPSIS
        Creates a private temp folder for one case. The runner deletes it again
        once that case returns.
    #>
    param([Parameter(Mandatory)][string] $Name)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("deploy-tests-$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $path
}
