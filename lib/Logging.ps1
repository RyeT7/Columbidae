<#
.SYNOPSIS
    Logging for the deploy pipeline, with bounded on-disk size.

.DESCRIPTION
    Appends timestamped lines to $script:LogFile and rotates it once it exceeds
    a size cap, so the log can never grow without limit on a storage-sensitive
    host.

    Rotation is size-based rather than time-based on purpose: the guarantee
    that matters here is a ceiling on bytes, not a tidy file-per-day.
    Steady-state worst case on disk is:

        (LogKeep + 1) * LogMaxBytes

    With the defaults (5 MB, 3 archives) that is roughly a 20 MB ceiling,
    reached only if something is failing on every tick. The bound holds because
    Write-Log checks the size before every append, so a file can only cross the
    threshold by one line before being rotated.

    The one case that exceeds it: a log that is already oversized when rotation
    first sees it -- dropped in by hand, or left behind after log_max_size_mb
    was lowered. It is archived whole rather than truncated, deliberately, so
    no history is destroyed; the ceiling reasserts itself once it cycles out.

.NOTES
    Dot-sourced by deploy-poll-lite.ps1, so $script:LogFile and friends resolve
    to the caller's script scope and are shared with every other lib file.

    Write-Log must never emit to the pipeline. Several callers do
    "return $someValue" in loops that also log; anything written to the
    pipeline here would be silently appended to their return value.
#>

# Set by the entry script once config has been read. Until then, console only.
$script:LogFile     = $null
$script:LogMaxBytes = 5MB
$script:LogKeep     = 3

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Rotates the log if it has grown past the cap. Never throws.

    .DESCRIPTION
        deploy.log -> deploy.log.1 -> deploy.log.2 -> ... -> dropped.

        Runs inline at the moment the file crosses the threshold rather than
        from any background process -- this pipeline leaves nothing resident,
        so housekeeping has to happen during a normal run.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $MaxBytes,
        [Parameter(Mandatory)][int] $Keep
    )

    try {
        if ($MaxBytes -le 0) { return }   # 0 or negative disables rotation
        if (-not (Test-Path -LiteralPath $Path)) { return }
        if ((Get-Item -LiteralPath $Path).Length -lt $MaxBytes) { return }

        # Drop the oldest archive, then shuffle each one up a number.
        $oldest = "$Path.$Keep"
        if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }

        for ($i = $Keep - 1; $i -ge 1; $i--) {
            $from = "$Path.$i"
            $to   = "$Path.$($i + 1)"
            if (Test-Path -LiteralPath $from) {
                if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Force }
                Move-Item -LiteralPath $from -Destination $to -Force
            }
        }

        if ($Keep -ge 1) {
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
        } else {
            # Keeping no archives at all: just discard.
            Remove-Item -LiteralPath $Path -Force
        }
    } catch {
        # Housekeeping must never break a deploy. Worst case the log keeps
        # growing and the next run tries again.
        Write-Host "WARN: log rotation failed: $($_.Exception.Message)"
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if ($script:LogFile) {
        try {
            Invoke-LogRotation -Path $script:LogFile -MaxBytes $script:LogMaxBytes -Keep $script:LogKeep
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        } catch {
            # Never let a logging failure abort a deploy that is otherwise fine.
            Write-Host "$line  (could not write to log: $($_.Exception.Message))"
        }
    }
}
