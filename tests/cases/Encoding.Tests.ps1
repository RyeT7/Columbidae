<#
.SYNOPSIS
    Repo-wide source lint rather than a test of any one lib file.

.DESCRIPTION
    PS 5.1 reads BOM-less .ps1 files as ANSI, so a stray non-ASCII character in
    source gets silently mangled on the deploy target.
#>

function Test-Encoding {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $nonAscii = @()
    Get-ChildItem -Path $RepoRoot -Recurse -Filter *.ps1 | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName)
        if ($content -cmatch '[^\x00-\x7F]') { $nonAscii += $_.Name }
    }
    Assert-Equal '' ($nonAscii -join ',') 'all .ps1 files are pure ASCII'
}
