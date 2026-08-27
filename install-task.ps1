<#
.SYNOPSIS
    Registers (or re-registers) the Task Scheduler entry that runs
    deploy-poll-lite.ps1. Run once, by hand, from an elevated prompt.

.DESCRIPTION
    An installer, not part of the deploy path. deploy-poll-lite.ps1
    deliberately does not register its own task: it runs every few minutes as
    SYSTEM on a machine several clients depend on, and letting the hot path
    rewrite the machine's scheduler config is a blast radius this design does
    not need. Scheduling is a one-time operation, so it lives in a one-time
    script.

    What this buys over the raw schtasks command it replaces: schtasks cannot
    set "If the task is already running, do not start a new instance" from the
    command line, so it had to be ticked by hand in the task's Settings tab --
    an overlap guarantee that depended on a human remembering a GUI step.
    Register-ScheduledTask can set it, so it is set here and read back
    afterwards to prove it took.

    Idempotent. Re-run it to reset a task that has drifted; it overwrites the
    named task and touches nothing else on the machine. It never touches IIS,
    the database, or the network.

.PARAMETER ConfigPath
    Path to the config.yaml this task should deploy from. Defaults to
    config.yaml next to this script. Deploying a second app means a second
    config file and a second task -- pass that file here.

.PARAMETER TaskName
    Name to register under. Defaults to "Columbidae Deploy Poll", suffixed with
    the config file's base name when it is not the default config.yaml, so
    installing a second app cannot silently overwrite the first one's task.

.PARAMETER IntervalMinutes
    Poll interval. Defaults to poll_interval_minutes from the config file (3 if
    that key is absent). Passing it here overrides the file for this install
    only, which makes the running task disagree with the config it was built
    from -- prefer editing the config.

.PARAMETER RunAsUser
    Account the task runs as. Defaults to SYSTEM, which needs no stored
    password and can modify IIS configuration.

.EXAMPLE
    .\install-task.ps1
    Register the default task from config.yaml beside this script.

.EXAMPLE
    .\install-task.ps1 -ConfigPath C:\deploy\api.yaml
    Register a second task for a second app, as "Columbidae Deploy Poll (api)".

.EXAMPLE
    .\install-task.ps1 -WhatIf
    Show what would be registered without touching the scheduler.

.NOTES
    Exit codes:
      0 - task registered and verified
      2 - could not install (not elevated, incomplete install, bad config,
          or the registered task did not match what was asked for)
    Requires: PowerShell 5.1, an elevated prompt, and the ScheduledTasks
    module (present on Windows 8 / Server 2012 and later).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.yaml'),
    [string] $TaskName,
    [int]    $IntervalMinutes,
    [string] $RunAsUser = 'SYSTEM'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DeployScript = Join-Path $PSScriptRoot 'deploy-poll-lite.ps1'

function Stop-WithError {
    param([Parameter(Mandatory)][string] $Message, [string] $Hint)

    Write-Host "FATAL: $Message"
    if ($Hint) { Write-Host $Hint }
    exit 2
}

#region Preflight

# Registering a task that runs as SYSTEM requires elevation. Checked up front
# so the failure is one clear line rather than an access-denied stack trace
# after the config has already been read -- but skipped under -WhatIf, which
# writes nothing and is the natural way to preview an install before finding
# an admin prompt.
if (-not $WhatIfPreference) {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-WithError 'This script must run from an elevated prompt.' `
            'Right-click PowerShell and choose "Run as administrator", then re-run.'
    }
}

if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    Stop-WithError 'The ScheduledTasks module is not available on this machine.' `
        'It ships with Windows 8 / Server 2012 and later.'
}

# Refuse to schedule an install that cannot run. The deploy script performs the
# same check at startup and exits 2, but a task that fails on every tick for
# days before anyone reads the log is worth preventing here instead.
$requiredLibs = @(
    'Logging.ps1', 'Config.ps1', 'Lock.ps1',
    'GitHub.ps1', 'Iis.ps1', 'Releases.ps1', 'Notify.ps1'
)
$libRoot = Join-Path $PSScriptRoot 'lib'
$missing = @($requiredLibs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $libRoot $_)) })

if (-not (Test-Path -LiteralPath $DeployScript)) {
    Stop-WithError "deploy-poll-lite.ps1 not found next to this script ($PSScriptRoot)." `
        'Copy the whole deploy folder as a unit, not just the installer.'
}
if ($missing.Count -gt 0) {
    Stop-WithError "Incomplete install. Missing lib file(s): $($missing -join ', ')" `
        'Copy the whole deploy folder (scripts + lib\ + config.yaml).'
}

#endregion

#region Configuration

. (Join-Path $libRoot 'Config.ps1')

try {
    $config = Read-FlatConfig -Path $ConfigPath

    # Read the settings the deploy script treats as required, purely to fail
    # here rather than on the first scheduled tick.
    Get-ConfigValue -Config $config -Key 'github_owner'  -Required | Out-Null
    Get-ConfigValue -Config $config -Key 'github_repo'   -Required | Out-Null
    Get-ConfigValue -Config $config -Key 'iis_site_name' -Required | Out-Null
    Get-ConfigValue -Config $config -Key 'health_url'    -Required | Out-Null
    Get-ConfigValue -Config $config -Key 'deploy_root'   -Required | Out-Null

    $healthRetries = Get-ConfigInt -Config $config -Key 'health_retries'             -Default 10
    $healthDelay   = Get-ConfigInt -Config $config -Key 'health_retry_delay_seconds' -Default 3
    $staleMinutes  = Get-ConfigInt -Config $config -Key 'lock_stale_minutes'         -Default 30

    if (-not $PSBoundParameters.ContainsKey('IntervalMinutes')) {
        $IntervalMinutes = Get-ConfigInt -Config $config -Key 'poll_interval_minutes' -Default 3
    }
} catch {
    Stop-WithError $_.Exception.Message
}

if ($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 1440) {
    Stop-WithError "poll_interval_minutes must be between 1 and 1440, got $IntervalMinutes."
}

if (-not $TaskName) {
    # A second app installed with the default name would overwrite the first
    # app's task, silently stopping its deploys. Derive the name from the
    # config file so that cannot happen by accident.
    $configBase = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $TaskName = if ($configBase -eq 'config') {
        'Columbidae Deploy Poll'
    } else {
        "Columbidae Deploy Poll ($configBase)"
    }
}

# The poll interval has to outlast a run, or most ticks just hit the overlap
# guard and skip -- harmless, but it fills the log with noise and delays real
# deploys. Only the health-check portion is predictable; download and extract
# depend on artifact size, hence a warning rather than a hard failure.
$healthWorstCaseSeconds = $healthRetries * $healthDelay * 2   # initial + post-rollback
if (($IntervalMinutes * 60) -lt ($healthWorstCaseSeconds + 60)) {
    Write-Host "WARNING: a failing deploy can spend $healthWorstCaseSeconds seconds in health checks alone,"
    Write-Host "         which is close to the $IntervalMinutes-minute poll interval. Expect skipped ticks."
}
if ($IntervalMinutes -ge $staleMinutes) {
    Write-Host "WARNING: poll interval ($IntervalMinutes min) is at or above lock_stale_minutes ($staleMinutes min)."
    Write-Host "         The overlap guard cannot do anything useful at that ratio."
}

#endregion

#region Register

function New-RepeatingTrigger {
    <#
    .SYNOPSIS
        A trigger that fires every $IntervalMinutes, forever.

    .DESCRIPTION
        -RepetitionDuration is the fiddly part across Windows builds:
        [TimeSpan]::MaxValue throws on some, and omitting it on others yields a
        trigger that fires once and never repeats -- a task that looks
        installed and silently stops deploying after its first tick. Writing
        the ISO 8601 durations onto the repetition pattern behaves consistently,
        and the caller re-reads the registered task rather than trusting it.
    #>
    param([Parameter(Mandatory)][int] $Minutes)

    # Anchored to midnight so ticks land on predictable clock times (:00, :03,
    # :06 ...) instead of wherever the install happened to run.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
        -RepetitionInterval (New-TimeSpan -Minutes $Minutes)

    if ($null -eq $trigger.Repetition) {
        throw 'This Windows build produced a trigger with no repetition pattern; the task would run once and stop.'
    }

    $trigger.Repetition.Interval = 'PT{0}M' -f $Minutes
    $trigger.Repetition.Duration = ''      # empty means repeat indefinitely
    return $trigger
}

# -ConfigPath is passed explicitly rather than relying on the default so that a
# second app's task is unambiguous about which config it deploys.
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $DeployScript, $ConfigPath

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument $arguments -WorkingDirectory $PSScriptRoot

# MultipleInstances IgnoreNew is the whole reason this script exists: it is
# "do not start a new instance", the second line of defense alongside the
# script's own lock file. ExecutionTimeLimit bounds a hung run -- the default
# is three days, which would sit on the lock far past lock_stale_minutes.
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ($staleMinutes * 2)) `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

$taskPrincipal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType ServiceAccount -RunLevel Highest

try {
    $trigger = New-RepeatingTrigger -Minutes $IntervalMinutes
} catch {
    Stop-WithError $_.Exception.Message
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Task:      $TaskName$(if ($existing) { ' (replacing existing)' })"
Write-Host "Runs:      powershell.exe $arguments"
Write-Host "As:        $RunAsUser"
Write-Host "Every:     $IntervalMinutes minute(s), indefinitely"
Write-Host "Overlap:   IgnoreNew (do not start a new instance)"
Write-Host "Time cap:  $($staleMinutes * 2) minutes"
Write-Host ''

if (-not $PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
    Write-Host 'WhatIf: nothing was registered.'
    exit 0
}

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $taskPrincipal -Force | Out-Null
} catch {
    Stop-WithError "Could not register the task: $($_.Exception.Message)"
}

#endregion

#region Verify

# Read the task back rather than trusting the call succeeded. The two
# properties worth proving are the ones with version-dependent behaviour and
# the one that guards against overlapping deploys.
$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $registered) {
    Stop-WithError 'The task was registered but cannot be read back.'
}

$problems = @()

$repetition = $registered.Triggers[0].Repetition
$expected   = 'PT{0}M' -f $IntervalMinutes
if ($null -eq $repetition -or $repetition.Interval -ne $expected) {
    $got = if ($repetition) { $repetition.Interval } else { '<none>' }
    $problems += "repetition interval is '$got', expected '$expected' -- the task may run once and stop"
}
if ($repetition -and $repetition.Duration) {
    $problems += "repetition duration is '$($repetition.Duration)' rather than indefinite -- polling will stop after that long"
}
if ($registered.Settings.MultipleInstances -ne 'IgnoreNew') {
    $problems += "overlap setting is '$($registered.Settings.MultipleInstances)', expected 'IgnoreNew'"
}

if ($problems.Count -gt 0) {
    Write-Host 'FATAL: the registered task does not match what was asked for:'
    foreach ($problem in $problems) { Write-Host "  - $problem" }
    Write-Host 'Open the task in Task Scheduler and correct it before relying on this.'
    exit 2
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "Registered and verified. State: $($registered.State). Next run: $($info.NextRunTime)"
Write-Host ''
Write-Host 'Run the deploy script by hand once before trusting the schedule:'
Write-Host "  .\deploy-poll-lite.ps1 -ConfigPath `"$ConfigPath`""
exit 0

#endregion
