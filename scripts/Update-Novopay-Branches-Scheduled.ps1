param(
    [int]$MinIdleMinutes = 0
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path $ScriptDir -Parent
. (Join-Path $ScriptDir 'Load-Config.ps1')
$cfg = Get-NovopayBranchUpdaterConfig -ToolRoot $ToolRoot

$MainScript = Join-Path $ScriptDir 'Update-Novopay-Branches.ps1'
if ($MinIdleMinutes -le 0) {
    $MinIdleMinutes = [int]$cfg.Scheduler.idleMinutes
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class UserIdleTime {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static int GetIdleMinutes() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) {
            return 0;
        }
        return (int)((Environment.TickCount - info.dwTime) / 60000);
    }
}
'@

if (-not (Test-Path $MainScript)) {
    exit 1
}

$idleMinutes = [UserIdleTime]::GetIdleMinutes()
if ($idleMinutes -lt $MinIdleMinutes) {
    exit 0
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript
exit $LASTEXITCODE
