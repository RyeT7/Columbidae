<#
.SYNOPSIS
    GitHub Releases access. The only network traffic this pipeline makes, and
    deliberately outbound-only -- nothing is permitted to connect inward to
    the deploy target.
#>

$script:UserAgent = 'deploy-poll-lite'

function Get-LatestRelease {
    param(
        [Parameter(Mandatory)][string] $Owner,
        [Parameter(Mandatory)][string] $Repo,
        [string] $Token,
        [int] $TimeoutSeconds = 120
    )

    $headers = @{
        'User-Agent'           = $script:UserAgent
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    $uri = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSeconds -Method Get
}

function Save-ReleaseAsset {
    param(
        [Parameter(Mandatory)] $Asset,
        [Parameter(Mandatory)][string] $Destination,
        [string] $Token,
        [int] $TimeoutSeconds = 120
    )

    # Public repos can use browser_download_url unauthenticated. Private repos
    # must go through the asset API with Accept: application/octet-stream --
    # and that endpoint 302s to S3, which rejects the request outright if the
    # GitHub Authorization header is forwarded. So the redirect is followed
    # manually, with auth stripped from the second hop.
    if (-not $Token) {
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Destination `
            -Headers @{ 'User-Agent' = $script:UserAgent } `
            -UseBasicParsing -TimeoutSec $TimeoutSeconds
        return
    }

    $headers = @{
        'User-Agent'           = $script:UserAgent
        'Accept'               = 'application/octet-stream'
        'Authorization'        = "Bearer $Token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    try {
        $response = Invoke-WebRequest -Uri $Asset.url -Headers $headers `
            -MaximumRedirection 0 -UseBasicParsing -TimeoutSec $TimeoutSeconds
        [System.IO.File]::WriteAllBytes($Destination, $response.Content)
        return
    } catch {
        $webResponse = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
            $webResponse = $_.Exception.Response
        }

        $status = if ($webResponse) { [int] $webResponse.StatusCode } else { 0 }
        if ($status -notin 301, 302, 303, 307, 308) { throw }

        $location = $webResponse.Headers['Location']
        if (-not $location) { throw "GitHub returned HTTP $status with no Location header." }

        Invoke-WebRequest -Uri $location -OutFile $Destination `
            -Headers @{ 'User-Agent' = $script:UserAgent } `
            -UseBasicParsing -TimeoutSec $TimeoutSeconds
    }
}
