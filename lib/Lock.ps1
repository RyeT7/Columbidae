<#
.SYNOPSIS
    Overlap guard: ensures only one deploy run works at a time.

.NOTES
    This is the script's own guard. Task Scheduler's "do not start a new
    instance" setting is a second line of defense, not a replacement for it;
    see the README for how to enable it.

    The lock is an exclusively-held open file handle, not just a file on disk,
    so a run that dies without cleaning up leaves a file nobody holds -- which
    is what makes the staleness check safe.
#>

function Enter-DeployLock {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int] $StaleMinutes
    )

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return [System.IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
        } catch [System.IO.IOException] {
            if ($attempt -eq 2) { return $null }

            # Either another run holds it, or a previous run died without
            # cleaning up. Age is the only thing that distinguishes the two.
            try {
                $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
            } catch {
                continue  # vanished between the failed open and the stat; retry
            }

            if ($age.TotalMinutes -lt $StaleMinutes) { return $null }

            Write-Log ("Breaking stale lock (age {0:N0} min, threshold {1} min)." -f $age.TotalMinutes, $StaleMinutes) 'WARN'
            try { Remove-Item -LiteralPath $Path -Force } catch { return $null }
        }
    }

    return $null
}

function Exit-DeployLock {
    param([System.IO.FileStream] $Stream, [string] $Path)

    # Only ever clean up a lock this run actually acquired. A null stream means
    # the lock belongs to a concurrent run -- deleting its file here would
    # disarm the overlap guard for everyone.
    if (-not $Stream) { return }

    $Stream.Dispose()

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { Remove-Item -LiteralPath $Path -Force } catch {
            Write-Log "Could not remove lock file '$Path': $($_.Exception.Message)" 'WARN'
        }
    }
}
