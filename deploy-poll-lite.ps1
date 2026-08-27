<#
.SYNOPSIS
    Stateless pull-based deployer for an IIS site. Run by Task Scheduler.

.DESCRIPTION
    Polls the configured GitHub repo's "latest" release. If it is newer than
    what is currently deployed, downloads the release asset, extracts it into a
    fresh release-<timestamp> folder, repoints the IIS site's physical path at
    it, health-checks the site, and rolls the physical path back if the health
    check fails.

    This script starts, does its work, and exits. Nothing is left resident
    between runs -- that is the core invariant of this design.
    It never builds or compiles anything, and it never touches the database on
    this VM. All network traffic is outbound HTTPS to GitHub.

    This file is orchestration only. The work lives in lib\*.ps1.

.PARAMETER ConfigPath
    Path to config.yaml. Defaults to config.yaml next to this script.

.PARAMETER Force
    Redeploy the latest release even if its tag is already recorded as
    deployed. For manual re-runs; the scheduled task should not pass this.

.EXAMPLE
    .\deploy-poll-lite.ps1
    A normal scheduled poll.

.EXAMPLE
    .\deploy-poll-lite.ps1 -ConfigPath C:\deploy\other-app.yaml -Force
    Manually redeploy a second app configured by its own config file.

.NOTES
    Exit codes:
      0 - nothing to do, or deploy succeeded
      1 - deploy failed and the site was rolled back
      2 - could not start (incomplete install, bad config, IIS unavailable,
          GitHub unreachable)
    Requires: PowerShell 5.1, the WebAdministration module (IIS management
    tools), and permission to modify the target site's configuration.
#>

[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.yaml'),
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Invoke-WebRequest's progress bar makes downloads an order of magnitude
# slower in PS 5.1, and nobody is watching a scheduled task's console anyway.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region Load libraries

# Dot-sourced rather than Import-Module on purpose. Dot-sourcing runs these in
# this script's scope, so $ErrorActionPreference = 'Stop' and the shared
# $script:LogFile apply inside them. A .psm1 module gets its own scope and
# would silently opt out of both -- errors that should abort a deploy would
# become non-terminating, and logging would go to a different variable.
$RequiredLibs = @(
    'Logging.ps1'    # Write-Log                          (load first: others log)
    'Config.ps1'     # Read-FlatConfig, Get-Config*
    'Lock.ps1'       # Enter-DeployLock, Exit-DeployLock
    'GitHub.ps1'     # Get-LatestRelease, Save-ReleaseAsset
    'Iis.ps1'        # Get/Set-SitePhysicalPath, Test-SiteHealth
    'Releases.ps1'   # Remove-OldReleases
    'Notify.ps1'     # Send-DeployNotification
)

$libRoot = Join-Path $PSScriptRoot 'lib'
$libPaths = $RequiredLibs | ForEach-Object { Join-Path $libRoot $_ }

# Verify the whole set before running any of it. A half-copied install on this
# box should fail here, loudly and before touching IIS, rather than halfway
# through a deploy.
$missing = @($libPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    Write-Host "FATAL: incomplete install. Missing lib file(s): $(($missing | Split-Path -Leaf) -join ', ')"
    Write-Host "Copy the whole deploy folder (script + lib\ + config.yaml), not just the script."
    exit 2
}

foreach ($libPath in $libPaths) { . $libPath }

#endregion

#region Configuration

try {
    $config = Read-FlatConfig -Path $ConfigPath

    $owner      = Get-ConfigValue -Config $config -Key 'github_owner'       -Required
    $repo       = Get-ConfigValue -Config $config -Key 'github_repo'        -Required
    $assetName  = Get-ConfigValue -Config $config -Key 'release_asset_name' -Default 'release.zip'
    $token      = Get-ConfigValue -Config $config -Key 'github_token'
    $siteName   = Get-ConfigValue -Config $config -Key 'iis_site_name'      -Required
    # "/" targets the site's root application; "/api" targets a sub-app under
    # it, so a frontend and backend sharing one site can deploy independently.
    $appPath    = Get-ConfigValue -Config $config -Key 'iis_app_path'       -Default '/'
    $healthUrl  = Get-ConfigValue -Config $config -Key 'health_url'         -Required
    $deployRoot = Get-ConfigValue -Config $config -Key 'deploy_root'        -Required
    $statePath  = Get-ConfigValue -Config $config -Key 'state_file' -Default (Join-Path $deployRoot 'deployed-tag.txt')
    $lockPath   = Get-ConfigValue -Config $config -Key 'lock_file'  -Default (Join-Path $deployRoot 'deploy.lock')
    $logPath    = Get-ConfigValue -Config $config -Key 'log_file'   -Default (Join-Path $deployRoot 'deploy.log')

    # Optional; blank webhook_url disables notifications entirely.
    $webhookUrl    = Get-ConfigValue -Config $config -Key 'webhook_url'
    $webhookFormat = Get-ConfigValue -Config $config -Key 'webhook_format' -Default 'raw'

    $healthRetries = Get-ConfigInt -Config $config -Key 'health_retries'             -Default 10
    $healthDelay   = Get-ConfigInt -Config $config -Key 'health_retry_delay_seconds' -Default 3
    $keepReleases  = Get-ConfigInt -Config $config -Key 'keep_releases'              -Default 5
    $staleMinutes  = Get-ConfigInt -Config $config -Key 'lock_stale_minutes'         -Default 30
    $httpTimeout   = Get-ConfigInt -Config $config -Key 'http_timeout_seconds'       -Default 120
    $webhookTimeout = Get-ConfigInt -Config $config -Key 'webhook_timeout_seconds'   -Default 10

    # Built here rather than mid-deploy so the failure paths can always name the
    # target, even when the run dies before reaching the swap.
    $targetLabel = if ($appPath -and $appPath.Trim('/', '\', ' ') -ne '') { "$siteName$appPath" } else { $siteName }

    foreach ($dir in @($deployRoot, (Split-Path -Parent $logPath), (Split-Path -Parent $lockPath))) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $script:LogFile = $logPath
} catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    exit 2
}

#endregion

#region Deploy

$lockStream = $null
# Initialised so the catch block can reference it even if the run dies before
# the release is known -- Set-StrictMode would throw on an unset variable.
$tag = ''

try {
    $lockStream = Enter-DeployLock -Path $lockPath -StaleMinutes $staleMinutes
    if (-not $lockStream) {
        # Previous run still going. Expected occasionally; not an error.
        Write-Log 'Another deploy run holds the lock; skipping this tick.'
        exit 0
    }

    Import-Module WebAdministration -ErrorAction Stop

    $release = Get-LatestRelease -Owner $owner -Repo $repo -Token $token -TimeoutSeconds $httpTimeout
    $tag = $release.tag_name
    if (-not $tag) { throw "GitHub returned a release with no tag_name for $owner/$repo." }

    $deployedTag = ''
    if (Test-Path -LiteralPath $statePath) {
        $deployedTag = (Get-Content -LiteralPath $statePath -Raw).Trim()
    }

    if ($tag -eq $deployedTag -and -not $Force) {
        # The common case. Deliberately not logged -- at a 2-5 minute poll
        # interval it would bury the entries that matter.
        Write-Verbose "Already on $tag; nothing to do."
        exit 0
    }

    Write-Log "New release '$tag' available (currently deployed: '$(if ($deployedTag) { $deployedTag } else { 'none' })')."

    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Release '$tag' has no asset named '$assetName'. Found: $(($release.assets | ForEach-Object { $_.name }) -join ', ')"
    }

    $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $releaseDir = Join-Path $deployRoot "release-$stamp"
    $zipPath    = Join-Path $deployRoot "download-$stamp.zip"

    Write-Log "Downloading $assetName ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    Save-ReleaseAsset -Asset $asset -Destination $zipPath -Token $token -TimeoutSeconds $httpTimeout

    Write-Log "Extracting to $releaseDir..."
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $releaseDir -Force
    Remove-Item -LiteralPath $zipPath -Force

    $previousPath = Get-SitePhysicalPath -SiteName $siteName -AppPath $appPath
    Write-Log "Repointing IIS target '$targetLabel': $previousPath -> $releaseDir"
    Set-SitePhysicalPath -SiteName $siteName -PhysicalPath $releaseDir -AppPath $appPath

    if (-not (Test-SiteHealth -Url $healthUrl -Retries $healthRetries -DelaySeconds $healthDelay)) {
        Write-Log "Health check failed after $healthRetries attempts. Rolling back to $previousPath." 'ERROR'
        Set-SitePhysicalPath -SiteName $siteName -PhysicalPath $previousPath -AppPath $appPath

        if (Test-SiteHealth -Url $healthUrl -Retries $healthRetries -DelaySeconds $healthDelay) {
            Write-Log "Rollback complete; target is healthy on the previous release. '$tag' was NOT deployed." 'ERROR'
            Send-DeployNotification -Url $webhookUrl -Format $webhookFormat -TimeoutSeconds $webhookTimeout `
                -Status 'rolled-back' -Tag $tag -Target $targetLabel `
                -Message "Health check failed after $healthRetries attempts. Rolled back to the previous release; the target is healthy. This release was NOT deployed."
        } else {
            Write-Log "ROLLBACK DID NOT RESTORE HEALTH. Target '$targetLabel' needs manual attention." 'ERROR'
            Send-DeployNotification -Url $webhookUrl -Format $webhookFormat -TimeoutSeconds $webhookTimeout `
                -Status 'rollback-failed' -Tag $tag -Target $targetLabel `
                -Message "Health check failed AND rollback did not restore health. The target is down and needs manual attention."
        }

        # The state file is deliberately left untouched so the next tick
        # retries this tag rather than silently marking it deployed.
        exit 1
    }

    Set-Content -LiteralPath $statePath -Value $tag -Encoding UTF8
    Write-Log "Deployed '$tag' successfully."
    Send-DeployNotification -Url $webhookUrl -Format $webhookFormat -TimeoutSeconds $webhookTimeout `
        -Status 'success' -Tag $tag -Target $targetLabel `
        -Message "Deployed successfully from $previousPath to $releaseDir. Health check passed."

    Remove-OldReleases -DeployRoot $deployRoot -Keep $keepReleases -Protected @($releaseDir, $previousPath)
    exit 0
} catch {
    Write-Log "Deploy run failed: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    Send-DeployNotification -Url $webhookUrl -Format $webhookFormat -TimeoutSeconds $webhookTimeout `
        -Status 'error' -Tag $tag -Target $targetLabel `
        -Message "Deploy run failed before completing: $($_.Exception.Message)"
    exit 2
} finally {
    Exit-DeployLock -Stream $lockStream -Path $lockPath
}

#endregion
