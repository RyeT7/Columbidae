<#
.SYNOPSIS
    IIS site/application manipulation and health checking.

.NOTES
    Requires the WebAdministration module (IIS management tools). The entry
    script imports it; these functions assume the IIS:\ drive exists.

    Targets either a site's root application or a sub-application within it
    (e.g. a "/api" backend under the same site as the "/" frontend), selected
    by the iis_app_path config key. Only that one physical path is ever
    touched -- nothing here restarts IIS, recycles unrelated pools, or goes
    near anything else running on the host.
#>

function Resolve-IisPath {
    <#
    .SYNOPSIS
        Builds the IIS:\ provider path for a site root or sub-application.

    .DESCRIPTION
        Pure string handling, kept separate from every call that touches IIS so
        it can be unit tested on a machine with no IIS installed.

        "/" (or empty) means the site's own root application:
            Resolve-IisPath -SiteName 'My Site'                  -> IIS:\Sites\My Site
            Resolve-IisPath -SiteName 'My Site' -AppPath '/api'  -> IIS:\Sites\My Site\api
            Resolve-IisPath -SiteName 'My Site' -AppPath 'api/v1'-> IIS:\Sites\My Site\api\v1
    #>
    param(
        [Parameter(Mandatory)][string] $SiteName,
        [string] $AppPath = '/'
    )

    if ([string]::IsNullOrWhiteSpace($SiteName)) {
        throw "SiteName must not be empty."
    }

    $base = "IIS:\Sites\$SiteName"

    # Accept "/api", "api", "/api/", "\api" and "" as the same thing.
    $trimmed = $AppPath
    if ($null -eq $trimmed) { $trimmed = '' }
    $trimmed = $trimmed.Trim().Replace('/', '\').Trim('\')

    if ($trimmed -eq '') { return $base }

    return "$base\$trimmed"
}

function Get-SitePhysicalPath {
    param(
        [Parameter(Mandatory)][string] $SiteName,
        [string] $AppPath = '/'
    )

    $iisPath = Resolve-IisPath -SiteName $SiteName -AppPath $AppPath

    $target = Get-Item -LiteralPath $iisPath -ErrorAction SilentlyContinue
    if (-not $target) {
        throw "IIS target '$iisPath' not found. Check iis_site_name and iis_app_path."
    }

    # Sites expose PhysicalPath directly; applications keep it on their root
    # virtual directory, which the provider surfaces as a physicalPath
    # property. Read it generically so both shapes work.
    $physicalPath = $null
    if ($target.PSObject.Properties.Name -contains 'PhysicalPath') {
        $physicalPath = $target.PhysicalPath
    }
    if ([string]::IsNullOrWhiteSpace($physicalPath)) {
        $prop = Get-ItemProperty -LiteralPath $iisPath -Name physicalPath -ErrorAction SilentlyContinue
        if ($prop) {
            $physicalPath = if ($prop.PSObject.Properties.Name -contains 'Value') { $prop.Value } else { $prop }
        }
    }
    if ([string]::IsNullOrWhiteSpace($physicalPath)) {
        throw "Could not read the current physical path of '$iisPath'."
    }

    # Paths may legitimately contain %SystemDrive% and friends; the value is
    # used later for comparison and rollback, so expand it once here.
    return [Environment]::ExpandEnvironmentVariables($physicalPath)
}

function Set-SitePhysicalPath {
    param(
        [Parameter(Mandatory)][string] $SiteName,
        [Parameter(Mandatory)][string] $PhysicalPath,
        [string] $AppPath = '/'
    )

    $iisPath = Resolve-IisPath -SiteName $SiteName -AppPath $AppPath
    Set-ItemProperty -LiteralPath $iisPath -Name physicalPath -Value $PhysicalPath
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
