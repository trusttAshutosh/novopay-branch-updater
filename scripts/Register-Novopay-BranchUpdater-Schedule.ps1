$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path $ScriptDir -Parent
. (Join-Path $ScriptDir 'Load-Config.ps1')
$cfg = Get-NovopayBranchUpdaterConfig -ToolRoot $ToolRoot

$TaskNamePrefix = $cfg.Scheduler.taskNamePrefix
$ScheduledScript = Join-Path $ScriptDir 'Update-Novopay-Branches-Scheduled.ps1'
$IdleMinutes = [int]$cfg.Scheduler.idleMinutes
$WaitHours = [int]$cfg.Scheduler.waitForIdleHours
$WeekdayTimes = @($cfg.Scheduler.weekdayTimes)

$Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScheduledScript`""

if (-not (Test-Path $ScheduledScript)) {
    throw "Scheduled wrapper not found: $ScheduledScript"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Argument

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -RunOnlyIfIdle `
    -IdleDuration (New-TimeSpan -Minutes $IdleMinutes) `
    -WaitForIdle (New-TimeSpan -Hours $WaitHours)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

function Register-UpdaterTask {
    param(
        [string]$Name,
        [string]$At
    )

    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $At
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "Registered: $Name at $At (weekdays, idle-only)"
}

$taskIndex = 0
foreach ($time in $WeekdayTimes) {
    $taskIndex++
    $label = if ($time -match '^0?9:') { '9AM' } elseif ($time -match '^21:') { '9PM' } else { "RUN$taskIndex" }
    Unregister-ScheduledTask -TaskName "$TaskNamePrefix $label" -Confirm:$false -ErrorAction SilentlyContinue
    Register-UpdaterTask -Name "$TaskNamePrefix $label" -At $time
}

Write-Host ''
Write-Host "Done. Idle required: $IdleMinutes min. Times: $($WeekdayTimes -join ', ')"
Write-Host 'Report opens in browser and is deleted when you close that tab.'
Write-Host ''
Write-Host 'To remove:'
Write-Host "  Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -like '$TaskNamePrefix*' | Unregister-ScheduledTask -Confirm:`$false"
