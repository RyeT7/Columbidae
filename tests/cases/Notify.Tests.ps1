<#
.SYNOPSIS
    Tests for lib\Notify.ps1 -- the webhook payload schema, and the guarantee
    that a broken webhook cannot break a deploy.
#>

function Test-Notify {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

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

    Write-Host "  failure isolation"
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
}
