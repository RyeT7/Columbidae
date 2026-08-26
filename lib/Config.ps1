<#
.SYNOPSIS
    Minimal flat "key: value" config reader.

.NOTES
    Deliberately not a YAML parser. See CLAUDE.md non-negotiable #6 before
    extending this -- adding nesting or lists here is the slippery slope that
    ends in depending on powershell-yaml being installed on the deploy VM.
#>

# Remembered by Read-FlatConfig so Get-ConfigValue can name the offending file
# without every call site having to pass the path in.
$script:ConfigSource = ''

function Read-FlatConfig {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $script:ConfigSource = $Path

    $config = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        # First colon only, so "C:\inetpub\..." and "http://host/x" survive.
        $split = $trimmed.IndexOf(':')
        if ($split -lt 1) { continue }

        $key   = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim()

        # Strip a trailing comment, but only when "#" follows whitespace, so
        # that URL fragments and tokens containing "#" survive.
        if ($value -match '^(.*?)\s+#') { $value = $Matches[1].Trim() }

        if ($value.Length -ge 2) {
            $first = $value[0]; $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $config[$key] = $value
    }

    return $config
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $Key,
        [string] $Default,
        [switch] $Required
    )

    $value = if ($Config.ContainsKey($Key)) { $Config[$Key] } else { '' }

    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            $where = if ($script:ConfigSource) { " in $($script:ConfigSource)" } else { '' }
            throw "Required setting '$Key' is missing or empty$where"
        }
        return $Default
    }

    return $value
}

function Get-ConfigInt {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][int] $Default
    )

    $raw = Get-ConfigValue -Config $Config -Key $Key
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

    $parsed = 0
    if (-not [int]::TryParse($raw, [ref] $parsed)) {
        throw "Setting '$Key' must be a whole number, got '$raw'"
    }

    return $parsed
}
