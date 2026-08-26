<#
.SYNOPSIS
    Logging for the deploy pipeline.

.NOTES
    Dot-sourced by deploy-poll-lite.ps1, so $script:LogFile resolves to the
    caller's script scope and is shared with every other lib file.

    Write-Log must never emit to the pipeline. Several callers do
    "return $someValue" in loops that also log; anything written to the
    pipeline here would be silently appended to their return value.
#>

# Set by the entry script once config has been read. Until then, console only.
$script:LogFile = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        } catch {
            # Never let a logging failure abort a deploy that is otherwise fine.
            Write-Host "$line  (could not write to log: $($_.Exception.Message))"
        }
    }
}
