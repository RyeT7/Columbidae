<#
.SYNOPSIS
    Tests for Remove-OldReleases in lib\Releases.ps1 -- pruning old release
    folders without ever deleting one that is live or rollback-worthy.
#>

function Test-Releases {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $pruneRoot = Join-Path $WorkDir 'releases'
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
}
