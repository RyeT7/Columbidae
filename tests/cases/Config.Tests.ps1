<#
.SYNOPSIS
    Tests for lib\Config.ps1 -- the hand-rolled flat "key: value" reader.
#>

function Test-Config {
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    # Covers the cases the hand-rolled parser has to get right: Windows paths
    # and URLs (embedded colons), comments, quotes, and blank values.
    $configFile = Join-Path $WorkDir 'test.yaml'
    @(
        '# a comment line'
        ''
        'github_owner: acme'
        'deploy_root: C:\inetpub\deployments\app'
        'health_url: http://localhost:8080/health'
        'quoted: "spaced value"'
        'single: ''sq value'''
        'trailing: value   # inline comment'
        'hash_in_value: pa#ssword'
        'blank_value:'
        'keep_releases: 7'
        'not_a_number: abc'
        'no_colon_line_ignored'
    ) | Set-Content -LiteralPath $configFile -Encoding UTF8

    $cfg = Read-FlatConfig -Path $configFile
    Assert-Equal 'acme'                             $cfg['github_owner']  'plain value'
    Assert-Equal 'C:\inetpub\deployments\app'       $cfg['deploy_root']   'Windows path keeps its drive colon'
    Assert-Equal 'http://localhost:8080/health'     $cfg['health_url']    'URL keeps scheme and port colons'
    Assert-Equal 'spaced value'                     $cfg['quoted']        'double quotes stripped'
    Assert-Equal 'sq value'                         $cfg['single']        'single quotes stripped'
    Assert-Equal 'value'                            $cfg['trailing']      'inline comment stripped'
    Assert-Equal 'pa#ssword'                        $cfg['hash_in_value'] '# without leading space is kept'
    Assert-Equal ''                                 $cfg['blank_value']   'blank value parses as empty'
    Assert-Equal $false                             $cfg.ContainsKey('no_colon_line_ignored') 'line without colon ignored'

    Assert-Equal 'acme'    (Get-ConfigValue -Config $cfg -Key 'github_owner' -Required) 'required value returned'
    Assert-Equal 'fallback' (Get-ConfigValue -Config $cfg -Key 'absent' -Default 'fallback') 'default used for absent key'
    Assert-Equal 'fallback' (Get-ConfigValue -Config $cfg -Key 'blank_value' -Default 'fallback') 'default used for blank value'
    Assert-Equal 7  (Get-ConfigInt -Config $cfg -Key 'keep_releases' -Default 5) 'int parsed'
    Assert-Equal 42 (Get-ConfigInt -Config $cfg -Key 'absent' -Default 42) 'int default used'

    Assert-Throws { Get-ConfigValue -Config $cfg -Key 'blank_value' -Required } 'required-but-blank throws'
    Assert-Throws { Get-ConfigInt -Config $cfg -Key 'not_a_number' -Default 1 } 'non-numeric int throws'
    Assert-Throws { Read-FlatConfig -Path (Join-Path $WorkDir 'nope.yaml') }    'missing config file throws'
}
