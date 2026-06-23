# Novopay branch updater - see ../README.md and ../config.json

param(
    [string]$Profile = '',
    [switch]$DryRun,
    [switch]$KeepReport,
    [int]$MaxParallel = 0
)

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path $ScriptDir -Parent
. (Join-Path $ScriptDir 'Load-Config.ps1')
. (Join-Path $ScriptDir 'Report-Builder.ps1')

$cfg = Get-NovopayBranchUpdaterConfig -ToolRoot $ToolRoot -ProfileName $Profile
if ($MaxParallel -le 0) { $MaxParallel = $cfg.MaxParallelRepos }
if ($KeepReport) { $cfg.KeepReport = $true }

$OpenReportScript = Join-Path $ScriptDir 'Open-Novopay-Report.ps1'
$ProcessRepoScript = Join-Path $ScriptDir 'Process-Single-Repo.ps1'
$RunId = Get-Date -Format 'yyyyMMddHHmmss'

function Get-RepoSortKey {
    param(
        [string]$RepoPath,
        [string]$RootPath,
        [string[]]$PreferredRepoOrder
    )
    $folder = if ($RepoPath -eq $RootPath) { '(root)' } else { Split-Path -Leaf $RepoPath }
    $idx = [array]::IndexOf($PreferredRepoOrder, $folder)
    if ($idx -ge 0) { return ('{0:D4}-{1}' -f $idx, $folder) }
    if ($folder -eq '(root)') { return '9999-(root)' }
    return "1000-$folder"
}

function Sort-ReposByPreferredOrder {
    param(
        [string[]]$RepoPaths,
        [string]$RootPath,
        [string[]]$PreferredRepoOrder
    )
    return $RepoPaths | Sort-Object -Unique { Get-RepoSortKey -RepoPath $_ -RootPath $RootPath -PreferredRepoOrder $PreferredRepoOrder }
}

function Merge-RepoResult {
    param(
        $Aggregate,
        $RepoResult
    )

    if ($RepoResult.PolicyLine) { $Aggregate.Policies.Add($RepoResult.PolicyLine) }
    $Aggregate.RepoTimings.Add([pscustomobject]@{
        Label = $RepoResult.Label
        Policy = $RepoResult.Policy
        BranchCount = $RepoResult.BranchCount
        DurationText = $RepoResult.DurationText
        DurationSeconds = $RepoResult.DurationSeconds
        Note = $RepoResult.Note
    })
    foreach ($item in $RepoResult.Conflicts) { $Aggregate.Conflicts.Add($item) }
    foreach ($item in $RepoResult.Skipped) { $Aggregate.Skipped.Add($item) }
    foreach ($item in $RepoResult.NotFound) { $Aggregate.NotFound.Add($item) }
    foreach ($item in $RepoResult.Updated) { $Aggregate.Updated.Add($item) }
    foreach ($item in $RepoResult.RepoErrors) { $Aggregate.RepoErrors.Add($item) }
    foreach ($item in $RepoResult.Excluded) { $Aggregate.Excluded.Add($item) }
    foreach ($item in $RepoResult.StashEvents) { $Aggregate.StashEvents.Add($item) }
    foreach ($item in $RepoResult.StashFailed) { $Aggregate.StashFailed.Add($item) }
    foreach ($item in $RepoResult.ShaChanges) { $Aggregate.ShaChanges.Add($item) }
}

# Discover repos
$repos = [System.Collections.Generic.List[string]]::new()
if (Test-Path (Join-Path $cfg.NovopayRoot '.git')) {
    $repos.Add($cfg.NovopayRoot)
}
Get-ChildItem -Path $cfg.NovopayRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if (Test-Path (Join-Path $_.FullName '.git')) {
        $repos.Add($_.FullName)
    }
}

$sortedRepos = @(Sort-ReposByPreferredOrder -RepoPaths @($repos) -RootPath $cfg.NovopayRoot -PreferredRepoOrder $cfg.PreferredRepoOrder)

$excludedAtDiscovery = [System.Collections.Generic.List[string]]::new()
$sortedRepos = @($sortedRepos | Where-Object {
    $folder = if ($_ -eq $cfg.NovopayRoot) { '(root)' } else { Split-Path -Leaf $_ }
    if ($cfg.ExcludedRepos -contains $folder) {
        $excludedAtDiscovery.Add("$folder (excluded in config)")
        return $false
    }
    return $true
})

$aggregate = [pscustomobject]@{
    Policies    = [System.Collections.Generic.List[string]]::new()
    RepoTimings = [System.Collections.Generic.List[psobject]]::new()
    Conflicts   = [System.Collections.Generic.List[string]]::new()
    Skipped     = [System.Collections.Generic.List[string]]::new()
    NotFound    = [System.Collections.Generic.List[string]]::new()
    Updated     = [System.Collections.Generic.List[string]]::new()
    RepoErrors  = [System.Collections.Generic.List[string]]::new()
    Excluded    = [System.Collections.Generic.List[string]]::new()
    StashEvents = [System.Collections.Generic.List[string]]::new()
    StashFailed = [System.Collections.Generic.List[string]]::new()
    ShaChanges  = [System.Collections.Generic.List[string]]::new()
}

foreach ($item in $excludedAtDiscovery) { $aggregate.Excluded.Add($item) }

$startedAt = Get-Date
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Novopay branch updater' -ForegroundColor Cyan
Write-Host " Root: $($cfg.NovopayRoot)" -ForegroundColor Cyan
Write-Host " Profile: $($cfg.ActiveProfile)" -ForegroundColor Cyan
Write-Host " Repos: $($sortedRepos.Count) | Parallel: $MaxParallel" -ForegroundColor Cyan
if ($excludedAtDiscovery.Count -gt 0) {
    Write-Host " Excluded: $($excludedAtDiscovery.Count) ($($excludedAtDiscovery -join ', '))" -ForegroundColor DarkGray
}
if ($DryRun) { Write-Host ' MODE: DRY RUN (no git changes)' -ForegroundColor Yellow }
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

if ($cfg.PreflightChecks) {
  . (Join-Path $ScriptDir 'Git-Helpers.ps1')
    $globalIssues = Invoke-PreflightChecks -NovopayRoot $cfg.NovopayRoot -MinFreeDiskGb $cfg.MinFreeDiskGb
    foreach ($issue in $globalIssues) {
        $aggregate.RepoErrors.Add($issue)
        Write-Host "PREFLIGHT: $issue" -ForegroundColor Red
    }
}

for ($i = 0; $i -lt $sortedRepos.Count; $i += $MaxParallel) {
    $batch = @($sortedRepos[$i..([Math]::Min($i + $MaxParallel - 1, $sortedRepos.Count - 1))])
    $jobs = @()

    foreach ($repoPath in $batch) {
        if ([string]::IsNullOrWhiteSpace($repoPath)) { continue }
        $jobs += Start-Job -ScriptBlock {
            param($ProcessScript, $Repo, $ToolRoot, $RunId, $DryRun, $ProfileName)
            & $ProcessScript -RepoPath $Repo -ToolRoot $ToolRoot -RunId $RunId -DryRun:$DryRun -ProfileName $ProfileName
        } -ArgumentList $ProcessRepoScript, $repoPath, $ToolRoot, $RunId, $DryRun.IsPresent, $Profile
    }

    $jobs | Wait-Job | Out-Null

    foreach ($job in $jobs) {
        $output = Receive-Job -Job $job
        foreach ($line in $output) {
            if ($line -is [string]) {
                Write-Host $line
            }
            elseif ($line.PSObject.Properties.Name -contains 'Label') {
                Merge-RepoResult -Aggregate $aggregate -RepoResult $line
            }
        }
        Remove-Job -Job $job
    }
}

$finishedAt = Get-Date
$duration = $finishedAt - $startedAt

$reportData = [pscustomobject]@{
    StartedAt    = $startedAt
    FinishedAt   = $finishedAt
    Duration     = $duration
    NovopayRoot  = $cfg.NovopayRoot
    Profile      = $cfg.ActiveProfile
    DryRun       = [bool]$DryRun
    MaxParallel  = $MaxParallel
    RepoCount    = $sortedRepos.Count
    ReportPath   = $cfg.ReportPath
    Conflicts    = $aggregate.Conflicts
    Skipped      = $aggregate.Skipped
    NotFound     = $aggregate.NotFound
    Updated      = $aggregate.Updated
    RepoErrors   = $aggregate.RepoErrors
    ShaChanges   = $aggregate.ShaChanges
    StashEvents  = $aggregate.StashEvents
    StashFailed  = $aggregate.StashFailed
    RepoTimings  = $aggregate.RepoTimings
}

$built = New-BranchUpdaterReport -Data $reportData
$built.Html | Set-Content -Path $cfg.ReportPath -Encoding UTF8
if ($cfg.WriteJson) {
    $built.Json | Set-Content -Path $cfg.ReportJsonPath -Encoding UTF8
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' DONE' -ForegroundColor Cyan
if ($DryRun) {
    Write-Host " Dry-run report: $($cfg.ReportPath)" -ForegroundColor Cyan
}
else {
    Write-Host ' Opening report in browser (file removed when tab closes unless -KeepReport)' -ForegroundColor Cyan
}
Write-Host '========================================' -ForegroundColor Cyan

$failureCount = $aggregate.Conflicts.Count + $aggregate.StashFailed.Count
if ($failureCount -gt 0) {
    Write-Host "Issues: $failureCount conflict(s)/stash failure(s)" -ForegroundColor Red
    if ($cfg.NotifyOnFailure) {
        Add-Type -AssemblyName System.Windows.Forms
        $summary = "Conflicts: $($aggregate.Conflicts.Count)`nStash restore failed: $($aggregate.StashFailed.Count)`nSkipped: $($aggregate.Skipped.Count)"
        [System.Windows.Forms.MessageBox]::Show($summary, 'Novopay Branch Updater', 'OK', 'Warning') | Out-Null
    }
}

if (-not $DryRun) {
    if ($cfg.KeepReport) {
        Write-Host "Report kept at: $($cfg.ReportPath)" -ForegroundColor DarkGray
        if ($cfg.WriteJson) { Write-Host "JSON kept at: $($cfg.ReportJsonPath)" -ForegroundColor DarkGray }
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OpenReportScript -ReportPath $cfg.ReportPath
        if ($cfg.WriteJson -and (Test-Path $cfg.ReportJsonPath)) {
            Remove-Item -Path $cfg.ReportJsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $(if ($failureCount -gt 0) { 2 } else { 0 })
