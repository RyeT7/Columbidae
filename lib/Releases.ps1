<#
.SYNOPSIS
    Housekeeping for extracted release folders under deploy_root.
#>

function Remove-OldReleases {
    param(
        [Parameter(Mandatory)][string] $DeployRoot,
        [Parameter(Mandatory)][int] $Keep,
        [string[]] $Protected = @()
    )

    $releases = @(Get-ChildItem -LiteralPath $DeployRoot -Directory -Filter 'release-*' |
        Sort-Object CreationTime -Descending)

    if ($releases.Count -le $Keep) { return }

    foreach ($release in $releases[$Keep..($releases.Count - 1)]) {
        # The live release and the rollback target are never pruned, however
        # old they are or however low Keep is set.
        if ($Protected -contains $release.FullName) { continue }

        try {
            Remove-Item -LiteralPath $release.FullName -Recurse -Force
            Write-Log "Pruned old release $($release.Name)."
        } catch {
            # Usually a file still held open by the app pool. Harmless; the
            # next run will try again.
            Write-Log "Could not prune $($release.Name): $($_.Exception.Message)" 'WARN'
        }
    }
}
