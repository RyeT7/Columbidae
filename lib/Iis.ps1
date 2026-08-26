<#
.SYNOPSIS
    IIS site manipulation and health checking.

.NOTES
    Requires the WebAdministration module (IIS management tools). The entry
    script imports it; these functions assume the IIS:\ drive exists.

    Only the site's root physical path is ever touched. Nothing here restarts
    IIS, recycles other pools, or goes near the database on this VM.
#>

function Get-SitePhysicalPath {
    param([Parameter(Mandatory)][string] $SiteName)

    $site = Get-Item -LiteralPath "IIS:\Sites\$SiteName" -ErrorAction SilentlyContinue
    if (-not $site) { throw "IIS site '$SiteName' not found." }

    # Site paths may legitimately contain %SystemDrive% and friends; the value
    # is used later for comparison and rollback, so expand it once here.
    return [Environment]::ExpandEnvironmentVariables($site.PhysicalPath)
}

function Set-SitePhysicalPath {
    param(
        [Parameter(Mandatory)][string] $SiteName,
        [Parameter(Mandatory)][string] $PhysicalPath
    )

    Set-ItemProperty -LiteralPath "IIS:\Sites\$SiteName" -Name physicalPath -Value $PhysicalPath
}

function Test-SiteHealth {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][int] $Retries,
        [Parameter(Mandatory)][int] $DelaySeconds
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
            if ($response.StatusCode -eq 200) {
                Write-Log "Health check passed on attempt $attempt (HTTP 200)."
                return $true
            }
            Write-Log "Health check attempt $attempt/$Retries returned HTTP $($response.StatusCode)." 'WARN'
        } catch {
            # Expected while the app pool is still spinning up the new release.
            Write-Log "Health check attempt $attempt/$Retries failed: $($_.Exception.Message)" 'WARN'
        }

        if ($attempt -lt $Retries) { Start-Sleep -Seconds $DelaySeconds }
    }

    return $false
}
