<#
.SYNOPSIS
    Tests for Resolve-IisPath in lib\Iis.ps1.

.DESCRIPTION
    Only Resolve-IisPath is exercised here; everything else in Iis.ps1 touches
    the IIS:\ provider and gets a CI parse check instead.
#>

function Test-Iis {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    # A frontend at "/" and a backend at "/api" under one site must resolve to
    # different provider paths, or the two configs would fight over one target.
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site')                'site root when AppPath omitted'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '/')   'site root for "/"'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '')    'site root for empty string'
    Assert-Equal 'IIS:\Sites\My Site'         (Resolve-IisPath -SiteName 'My Site' -AppPath '  ')  'site root for whitespace'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '/api')   'leading slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath 'api')    'no leading slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '/api/')  'trailing slash'
    Assert-Equal 'IIS:\Sites\My Site\api'     (Resolve-IisPath -SiteName 'My Site' -AppPath '\api')   'backslash accepted'
    Assert-Equal 'IIS:\Sites\My Site\api\v1'  (Resolve-IisPath -SiteName 'My Site' -AppPath '/api/v1') 'nested application'
    Assert-Equal $true ((Resolve-IisPath -SiteName 'S' -AppPath '/') -ne (Resolve-IisPath -SiteName 'S' -AppPath '/api')) 'root and sub-app differ'
    Assert-Throws { Resolve-IisPath -SiteName '' -AppPath '/api' } 'empty site name throws'
}
