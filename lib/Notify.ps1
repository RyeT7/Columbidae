<#
.SYNOPSIS
    Optional webhook notifications for deploy outcomes.

.DESCRIPTION
    Emits a single platform-neutral JSON event. Chat-specific payload shapes
    (Slack, Discord, Teams) are deliberately NOT built in -- reshaping an event
    for a particular destination is a consumer's job, and doing it here would
    put platform knowledge in the deploy path.

    The event schema is a contract consumers depend on, so treat it as stable:

        {
          "status":    "success" | "rolled-back" | "rollback-failed" | "error",
          "tag":       "deploy-<sha>"   release tag, "" if not yet known
          "target":    "My Site/api"    IIS site, plus app path when not root
          "message":   "human-readable detail"
          "host":      "WEBVM01"        which deploy target reported this
          "timestamp": "2026-08-26T14:22:30Z"   UTC, ISO 8601
        }

    Adding fields is safe; renaming or removing them is not.

.NOTES
    Two rules govern everything here:

      1. A notification failure must NEVER fail a deploy. Every send is wrapped
         in try/catch and downgraded to a WARN. This is the least important
         thing in the pipeline and has to behave like it.
      2. Every send has an explicit timeout. Invoke-RestMethod's -TimeoutSec
         defaults to 0, meaning indefinite -- an endpoint that accepts the TCP
         connection but never responds would otherwise hang the run forever,
         holding the deploy lock until the stale-lock threshold breaks it.

    ASCII only, deliberately. Windows PowerShell 5.1 reads .ps1 files without a
    BOM as ANSI, so non-ASCII characters in source get mangled on the target.

    -Format is the extension point for future platform adapters. 'raw' is the
    only one implemented; add cases to the switch and the ValidateSet together.
#>

function New-NotificationPayload {
    <#
    .SYNOPSIS
        Builds the JSON body for a webhook. Pure -- no network, no side effects.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('success', 'rolled-back', 'rollback-failed', 'error')][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string] $Tag = '',
        [string] $Target = ''
    )

    return (@{
        status    = $Status
        tag       = $Tag
        target    = $Target
        message   = $Message
        host      = $env:COMPUTERNAME
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json -Compress -Depth 3)
}

function Send-DeployNotification {
    <#
    .SYNOPSIS
        POSTs a deploy outcome to the configured webhook. Never throws.
    #>
    param(
        [string] $Url,
        [string] $Format = 'raw',
        [Parameter(Mandatory)][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string] $Tag = '',
        [string] $Target = '',
        [int] $TimeoutSeconds = 10
    )

    # Not configured: notifications are opt-in.
    if ([string]::IsNullOrWhiteSpace($Url)) { return }

    try {
        $body = New-NotificationPayload -Status $Status `
            -Message $Message -Tag $Tag -Target $Target

        # Out-Null matters: this function must emit nothing to the pipeline.
        Invoke-RestMethod -Uri $Url -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec $TimeoutSeconds | Out-Null

        Write-Log "Notification sent ($Status)."
    } catch {
        # Deliberately swallowed. A broken webhook is not a broken deploy.
        Write-Log "Notification failed, deploy unaffected: $($_.Exception.Message)" 'WARN'
    }
}
