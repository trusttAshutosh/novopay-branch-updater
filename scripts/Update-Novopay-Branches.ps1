# Novopay branch updater - see ../README.md and ../config.json

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$ToolRoot = Split-Path $ScriptDir -Parent
. (Join-Path $ScriptDir 'Load-Config.ps1')
$cfg = Get-NovopayBranchUpdaterConfig -ToolRoot $ToolRoot

$RootPath              = $cfg.NovopayRoot
$FrontendRepos         = $cfg.FrontendRepos
$FrontendBranches      = $cfg.FrontendBranches
$BackendBranches       = $cfg.BackendBranches
$AllLocalBranchesRepos = $cfg.AllLocalBranchesRepos
$ExcludedReposConfig   = $cfg.ExcludedRepos
$PreferredRepoOrder    = $cfg.PreferredRepoOrder
$ReportPath            = $cfg.ReportPath
$OpenReportScript      = Join-Path $ScriptDir 'Open-Novopay-Report.ps1'

$conflicts      = [System.Collections.Generic.List[string]]::new()
$skipped        = [System.Collections.Generic.List[string]]::new()
$notFound       = [System.Collections.Generic.List[string]]::new()
$updated        = [System.Collections.Generic.List[string]]::new()
$repoErrors     = [System.Collections.Generic.List[string]]::new()
$excludedRepos  = [System.Collections.Generic.List[string]]::new()
$repoPolicies   = [System.Collections.Generic.List[string]]::new()
$stashEvents    = [System.Collections.Generic.List[string]]::new()
$stashFailed    = [System.Collections.Generic.List[string]]::new()
$repoTimings    = [System.Collections.Generic.List[psobject]]::new()

$RunId = Get-Date -Format 'yyyyMMddHHmmss'

function Get-RepoLabel {
    param([string]$RepoPath)
    if ($RepoPath -eq $RootPath) { return '(root)' }
    return $RepoPath.Substring($RootPath.Length).TrimStart('\', '/')
}

function Get-RepoFolderName {
    param([string]$RepoPath)
    if ($RepoPath -eq $RootPath) { return '(root)' }
    return Split-Path -Leaf $RepoPath
}

function Get-RepoSortKey {
    param([string]$RepoPath)

    $folder = Get-RepoFolderName -RepoPath $RepoPath
    $idx = [array]::IndexOf($PreferredRepoOrder, $folder)
    if ($idx -ge 0) {
        return ('{0:D4}-{1}' -f $idx, $folder)
    }
    if ($folder -eq '(root)') {
        return '9999-(root)'
    }
    return "1000-$folder"
}

function Sort-ReposByPreferredOrder {
    param([string[]]$RepoPaths)
    return $RepoPaths | Sort-Object -Unique { Get-RepoSortKey $_ }
}

function Get-RepoPolicy {
    param([string]$RepoPath)

    $folder = Get-RepoFolderName -RepoPath $RepoPath
    if ($ExcludedReposConfig -contains $folder) {
        return @{ Type = 'skip'; Label = 'excluded by config' }
    }
    if ($AllLocalBranchesRepos -contains $folder) {
        return @{ Type = 'all-local'; Label = 'all local branches' }
    }
    if ($FrontendRepos -contains $folder) {
        return @{ Type = 'list'; Branches = $FrontendBranches; Label = 'frontend (dsa branches)' }
    }
    return @{ Type = 'list'; Branches = $BackendBranches; Label = 'backend (ddp branches)' }
}

function Invoke-Git {
    param(
        [string[]]$GitArguments,
        [string]$WorkDir
    )
    $output = & git -C $WorkDir @GitArguments 2>&1
    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

function Test-GitRef {
    param(
        [string]$WorkDir,
        [string]$Ref
    )
    $r = Invoke-Git -GitArguments @('rev-parse', '--verify', $Ref) -WorkDir $WorkDir
    return $r.ExitCode -eq 0
}

function Abort-InProgressGitOps {
    param([string]$WorkDir)

    if (Test-Path (Join-Path $WorkDir '.git\MERGE_HEAD')) {
        Invoke-Git -GitArguments @('merge', '--abort') -WorkDir $WorkDir | Out-Null
    }
    if (Test-Path (Join-Path $WorkDir '.git\REBASE_HEAD')) {
        Invoke-Git -GitArguments @('rebase', '--abort') -WorkDir $WorkDir | Out-Null
    }
    if (Test-Path (Join-Path $WorkDir '.git\CHERRY_PICK_HEAD')) {
        Invoke-Git -GitArguments @('cherry-pick', '--abort') -WorkDir $WorkDir | Out-Null
    }
}

function Test-DirtyWorkingTree {
    param([string]$WorkDir)
    $status = Invoke-Git -GitArguments @('status', '--porcelain') -WorkDir $WorkDir
    return [bool]$status.Output
}

function Save-RepoWorktree {
    param(
        [string]$WorkDir,
        [string]$RepoLabel,
        [string]$StashMessage
    )

    if (-not (Test-DirtyWorkingTree -WorkDir $WorkDir)) {
        return $false
    }

    $stash = Invoke-Git -GitArguments @('stash', 'push', '-u', '-m', $StashMessage) -WorkDir $WorkDir
    if ($stash.ExitCode -ne 0) {
        $script:repoErrors.Add("$RepoLabel (auto-stash failed: $($stash.Output -replace '\s+', ' '))")
        return $false
    }
    if ($stash.Output -match 'No local changes to save') {
        return $false
    }

    $script:stashEvents.Add("$RepoLabel (stashed uncommitted changes before fetch)")
    Write-Host '   Stashed uncommitted changes' -ForegroundColor DarkCyan
    return $true
}

function Restore-RepoWorktree {
    param(
        [string]$WorkDir,
        [string]$RepoLabel,
        [string]$OriginalBranch,
        [bool]$HadStash
    )

    if ($OriginalBranch -and $OriginalBranch -ne 'HEAD') {
        $checkout = Invoke-Git -GitArguments @('checkout', $OriginalBranch) -WorkDir $WorkDir
        if ($checkout.ExitCode -ne 0) {
            $script:stashFailed.Add("$RepoLabel (failed to return to $OriginalBranch before unstash: $($checkout.Output -replace '\s+', ' '))")
            return
        }
    }

    if (-not $HadStash) {
        return
    }

    $pop = Invoke-Git -GitArguments @('stash', 'pop') -WorkDir $WorkDir
    if ($pop.ExitCode -ne 0) {
        $script:stashFailed.Add("$RepoLabel (failed to restore stash on $OriginalBranch : $($pop.Output -replace '\s+', ' '))")
        return
    }

    $script:stashEvents.Add("$RepoLabel (restored uncommitted changes on $OriginalBranch, stash deleted)")
    Write-Host "   Restored uncommitted changes on $OriginalBranch" -ForegroundColor DarkCyan
}

function Update-Branch {
    param(
        [string]$WorkDir,
        [string]$RepoLabel,
        [string]$Branch,
        [switch]$SkipPerBranchFetch
    )

    $entry = "$RepoLabel / $Branch"

    $localRef  = Test-GitRef -WorkDir $WorkDir -Ref $Branch
    $remoteRef = Test-GitRef -WorkDir $WorkDir -Ref "origin/$Branch"

    if (-not $localRef -and -not $remoteRef) {
        $script:notFound.Add("$entry (branch not on local or origin)")
        return 'not-found'
    }

    if ($localRef) {
        $checkout = Invoke-Git -GitArguments @('checkout', $Branch) -WorkDir $WorkDir
    }
    else {
        $checkout = Invoke-Git -GitArguments @('checkout', '-B', $Branch, "origin/$Branch") -WorkDir $WorkDir
    }

    if ($checkout.ExitCode -ne 0) {
        $script:skipped.Add("$entry (checkout failed: $($checkout.Output -replace '\s+', ' '))")
        return 'skipped'
    }

    if (-not $SkipPerBranchFetch) {
        $fetch = Invoke-Git -GitArguments @('fetch', 'origin', $Branch) -WorkDir $WorkDir
        if ($fetch.ExitCode -ne 0) {
            $script:skipped.Add("$entry (fetch failed: $($fetch.Output -replace '\s+', ' '))")
            return 'skipped'
        }
    }

    if (-not (Test-GitRef -WorkDir $WorkDir -Ref "origin/$Branch")) {
        $script:notFound.Add("$entry (no origin/$Branch after fetch)")
        return 'not-found'
    }

    $merge = Invoke-Git -GitArguments @('merge', '--no-edit', "origin/$Branch") -WorkDir $WorkDir
    if ($merge.ExitCode -ne 0) {
        Abort-InProgressGitOps -WorkDir $WorkDir
        $script:conflicts.Add($entry)
        return 'conflict'
    }

    if ($merge.Output -match 'Already up to date') {
        $script:updated.Add("$entry (already up to date)")
    }
    else {
        $script:updated.Add("$entry (updated)")
    }
    return 'ok'
}

function Write-BranchResult {
    param([string]$Result)
    switch ($Result) {
        'conflict'  { Write-Host ' -> MERGE CONFLICT (aborted)' -ForegroundColor Red }
        'skipped'   { Write-Host ' -> skipped' -ForegroundColor DarkYellow }
        'not-found' { Write-Host ' -> not found' -ForegroundColor DarkGray }
        default     { Write-Host ' -> ok' -ForegroundColor Green }
    }
}

function Escape-Html {
    param([string]$Text)
    if (-not $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-Duration {
    param([timespan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return $Duration.ToString('h\:mm\:ss')
    }
    if ($Duration.TotalSeconds -ge 60) {
        return $Duration.ToString('m\:ss')
    }
    return ('{0:N1}s' -f $Duration.TotalSeconds)
}

function Record-RepoTiming {
    param(
        [string]$Label,
        [string]$Policy,
        [int]$BranchCount,
        [datetime]$StartedAt,
        [string]$Note = 'updated'
    )

    $duration = (Get-Date) - $StartedAt
    $entry = [pscustomobject]@{
        Label        = $Label
        Policy       = $Policy
        BranchCount  = $BranchCount
        Duration     = $duration
        DurationText = Format-Duration -Duration $duration
        Note         = $Note
    }
    $script:repoTimings.Add($entry)
    Write-Host "   Time: $($entry.DurationText) for $BranchCount branch(es)" -ForegroundColor DarkGray
}

function New-HtmlListRows {
    param(
        [System.Collections.Generic.List[string]]$Items,
        [string]$RowClass = ''
    )
    if ($Items.Count -eq 0) {
        return "<tr><td class='empty' colspan='2'>(none)</td></tr>"
    }
    $rows = @()
    $i = 0
    foreach ($item in $Items) {
        $i++
        $classAttr = if ($RowClass) { " class='$RowClass'" } else { '' }
        $rows += "<tr$classAttr><td class='num'>$i</td><td>$(Escape-Html $item)</td></tr>"
    }
    return $rows -join "`n"
}

function New-HtmlRepoTimingRows {
    param(
        [System.Collections.Generic.List[psobject]]$Timings
    )

    if ($Timings.Count -eq 0) {
        return "<tr><td class='empty' colspan='6'>(none)</td></tr>"
    }

    $rows = @()
    $i = 0
    foreach ($item in ($Timings | Sort-Object Duration -Descending)) {
        $i++
        $rows += @"
<tr>
  <td class='num'>$i</td>
  <td>$(Escape-Html $item.Label)</td>
  <td>$(Escape-Html $item.Policy)</td>
  <td class='num'>$($item.BranchCount)</td>
  <td><strong>$(Escape-Html $item.DurationText)</strong></td>
  <td>$(Escape-Html $item.Note)</td>
</tr>
"@
    }
    return $rows -join "`n"
}

function New-HtmlReport {
    param(
        [datetime]$StartedAt,
        [datetime]$FinishedAt,
        [timespan]$Duration,
        [string]$ReportPath,
        [int]$RepoCount,
        [System.Collections.Generic.List[string]]$Policies,
        [System.Collections.Generic.List[string]]$Excluded,
        [System.Collections.Generic.List[string]]$ConflictItems,
        [System.Collections.Generic.List[string]]$SkippedItems,
        [System.Collections.Generic.List[string]]$NotFoundItems,
        [System.Collections.Generic.List[string]]$ErrorItems,
        [System.Collections.Generic.List[string]]$UpdatedItems,
        [System.Collections.Generic.List[string]]$StashEventItems,
        [System.Collections.Generic.List[string]]$StashFailedItems,
        [System.Collections.Generic.List[psobject]]$RepoTimingItems
    )

    $conflictCount = $ConflictItems.Count
    $statusClass   = if ($conflictCount -gt 0) { 'warn' } else { 'ok' }
    $statusLabel   = if ($conflictCount -gt 0) { "$conflictCount merge conflict(s)" } else { 'All branches updated cleanly' }

    $policyRows = ($Policies | ForEach-Object { "<li>$(Escape-Html $_)</li>" }) -join "`n"
    $slowestRepo = $RepoTimingItems | Sort-Object Duration -Descending | Select-Object -First 1
    $slowestText = if ($slowestRepo) {
        "$(Escape-Html $slowestRepo.Label) - $(Escape-Html $slowestRepo.DurationText) ($($slowestRepo.BranchCount) branches)"
    } else {
        '(none)'
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Novopay Branch Update Report</title>
  <style>
    :root {
      --bg: #f4f6f8;
      --card: #ffffff;
      --text: #1a1a2e;
      --muted: #5c6370;
      --border: #dde3ea;
      --ok: #0f7b3c;
      --ok-bg: #e8f5ee;
      --warn: #b45309;
      --warn-bg: #fef3c7;
      --bad: #b91c1c;
      --bad-bg: #fee2e2;
      --info: #1d4ed8;
      --info-bg: #dbeafe;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .wrap { max-width: 1100px; margin: 0 auto; padding: 24px 20px 48px; }
    header {
      background: linear-gradient(135deg, #0f172a, #1e3a5f);
      color: #fff;
      border-radius: 12px;
      padding: 28px 32px;
      margin-bottom: 24px;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.18);
    }
    header h1 { margin: 0 0 8px; font-size: 1.75rem; }
    header p { margin: 4px 0; color: #cbd5e1; font-size: 0.95rem; }
    .status-pill {
      display: inline-block;
      margin-top: 12px;
      padding: 6px 12px;
      border-radius: 999px;
      font-weight: 600;
      font-size: 0.9rem;
    }
    .status-pill.ok { background: var(--ok-bg); color: var(--ok); }
    .status-pill.warn { background: var(--warn-bg); color: var(--warn); }
    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 14px;
      margin-bottom: 24px;
    }
    .stat {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 16px;
      text-align: center;
    }
    .stat .value { font-size: 1.8rem; font-weight: 700; }
    .stat .label { color: var(--muted); font-size: 0.85rem; margin-top: 4px; }
    .stat.ok .value { color: var(--ok); }
    .stat.warn .value { color: var(--warn); }
    .stat.bad .value { color: var(--bad); }
    .stat.info .value { color: var(--info); }
    section {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 10px;
      margin-bottom: 18px;
      overflow: hidden;
    }
    section h2 {
      margin: 0;
      padding: 14px 18px;
      font-size: 1.05rem;
      border-bottom: 1px solid var(--border);
      background: #f8fafc;
    }
    section h2.conflict { background: var(--bad-bg); color: var(--bad); }
    section h2.success { background: var(--ok-bg); color: var(--ok); }
    .content { padding: 16px 18px; }
    ul.policies { margin: 0; padding-left: 20px; }
    ul.policies li { margin: 4px 0; }
    table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
    th, td { padding: 10px 12px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
    th { background: #f8fafc; color: var(--muted); font-weight: 600; width: 48px; }
    tr.conflict td { background: var(--bad-bg); }
    tr.success td { background: #f8fffb; }
    td.empty { color: var(--muted); font-style: italic; }
    td.num { color: var(--muted); width: 48px; }
    .timing-summary { margin: 0 0 12px; color: var(--muted); font-size: 0.92rem; }
    .meta-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 10px 18px;
      font-size: 0.92rem;
    }
    .meta-grid dt { color: var(--muted); margin: 0; }
    .meta-grid dd { margin: 0 0 8px; font-weight: 600; }
    footer { margin-top: 20px; color: var(--muted); font-size: 0.82rem; text-align: center; }
  </style>
</head>
<body>
  <div class="wrap">
    <header>
      <h1>Novopay Branch Update Report</h1>
      <p>Generated: $(Escape-Html $FinishedAt.ToString('yyyy-MM-dd HH:mm:ss'))</p>
      <p>Duration: $(Escape-Html $Duration.ToString('hh\:mm\:ss'))</p>
      <p>Root: $(Escape-Html $RootPath)</p>
      <span class="status-pill $statusClass">$statusLabel</span>
    </header>

    <div class="stats">
      <div class="stat info"><div class="value">$RepoCount</div><div class="label">Repos scanned</div></div>
      <div class="stat"><div class="value">$($Excluded.Count)</div><div class="label">Excluded</div></div>
      <div class="stat ok"><div class="value">$($UpdatedItems.Count)</div><div class="label">Updated OK</div></div>
      <div class="stat bad"><div class="value">$conflictCount</div><div class="label">Merge conflicts</div></div>
      <div class="stat warn"><div class="value">$($SkippedItems.Count)</div><div class="label">Skipped</div></div>
      <div class="stat"><div class="value">$($NotFoundItems.Count)</div><div class="label">Branch missing</div></div>
      <div class="stat warn"><div class="value">$($ErrorItems.Count)</div><div class="label">Repo errors</div></div>
    </div>

    <section>
      <h2>Repo update timing</h2>
      <div class="content">
        <p class="timing-summary">Slowest repo: $slowestText</p>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>Repo</th>
              <th>Policy</th>
              <th>Branches</th>
              <th>Duration</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>$(New-HtmlRepoTimingRows -Timings $RepoTimingItems)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>Branch policies</h2>
      <div class="content">
        <dl class="meta-grid">
          <dt>Frontend repos</dt><dd>$(Escape-Html ($FrontendRepos -join ', '))</dd>
          <dt>Frontend branches</dt><dd>$(Escape-Html ($FrontendBranches -join ', '))</dd>
          <dt>Backend branches</dt><dd>$(Escape-Html ($BackendBranches -join ', '))</dd>
          <dt>Excluded repos</dt><dd>$(Escape-Html ($(if ($ExcludedReposConfig.Count) { $ExcludedReposConfig -join ', ' } else { '(none)' })))</dd>
          <dt>All-local repos</dt><dd>$(Escape-Html ($AllLocalBranchesRepos -join ', '))</dd>
          <dt>Repo processing order</dt><dd>$(Escape-Html ($PreferredRepoOrder -join ' -> ')) -> others (A-Z)</dd>
        </dl>
        <ul class="policies">$policyRows</ul>
      </div>
    </section>

    <section>
      <h2>Excluded repos</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Repo</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $Excluded)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>Stash / restore</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Detail</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $StashEventItems)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2 class="conflict">Stash restore failures</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Detail</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $StashFailedItems -RowClass 'conflict')</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2 class="conflict">Merge conflicts (could not update)</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Repo / branch</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $ConflictItems -RowClass 'conflict')</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>Skipped (non-conflict)</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Detail</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $SkippedItems)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>Branch not found</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Detail</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $NotFoundItems)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>Repo errors</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Detail</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $ErrorItems)</tbody>
        </table>
      </div>
    </section>

    <section>
      <h2 class="success">Successfully updated</h2>
      <div class="content">
        <table>
          <thead><tr><th>#</th><th>Repo / branch</th></tr></thead>
          <tbody>$(New-HtmlListRows -Items $UpdatedItems -RowClass 'success')</tbody>
        </table>
      </div>
    </section>

    <footer>Report file: $(Escape-Html $ReportPath)</footer>
  </div>
</body>
</html>
"@
}

function Get-LocalBranches {
    param([string]$WorkDir)

    $result = Invoke-Git -GitArguments @('branch', '--format=%(refname:short)') -WorkDir $WorkDir
    if ($result.ExitCode -ne 0 -or -not $result.Output) {
        return @()
    }
    return $result.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Discover repos: novopay root (if .git) + immediate child folders with .git
$repos = [System.Collections.Generic.List[string]]::new()
if (Test-Path (Join-Path $RootPath '.git')) {
    $repos.Add($RootPath)
}
Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if (Test-Path (Join-Path $_.FullName '.git')) {
        $repos.Add($_.FullName)
    }
}

$startedAt = Get-Date
Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Novopay branch updater' -ForegroundColor Cyan
Write-Host " Root: $RootPath" -ForegroundColor Cyan
Write-Host " Repos: $($repos.Count)" -ForegroundColor Cyan
Write-Host ' Policies:' -ForegroundColor Cyan
Write-Host "   Frontend ($($FrontendRepos -join ', ')): $($FrontendBranches -join ', ')" -ForegroundColor Cyan
Write-Host "   Backend (all others): $($BackendBranches -join ', ')" -ForegroundColor Cyan
Write-Host "   Excluded: $(if ($ExcludedReposConfig.Count) { $ExcludedReposConfig -join ', ' } else { '(none)' })" -ForegroundColor Cyan
Write-Host "   All-local repos: $($AllLocalBranchesRepos -join ', ')" -ForegroundColor Cyan
Write-Host '   Repo order: lib, creditcard, masterdata, gateway, actor, consents, notifications, initial-setup, banking-origination, batch, approval, then others' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

$sortedRepos = Sort-ReposByPreferredOrder -RepoPaths $repos

foreach ($repoPath in $sortedRepos) {
    $repoStartedAt = Get-Date
    $branchCount = 0
    $timingNote = 'updated'
    $label  = Get-RepoLabel -RepoPath $repoPath
    $policy = Get-RepoPolicy -RepoPath $repoPath
    $repoPolicies.Add("$label -> $($policy.Label)")

    Write-Host ">> $label [$($policy.Label)]" -ForegroundColor Yellow

    if ($policy.Type -eq 'skip') {
        $excludedRepos.Add("$label (skipped - excluded in config)")
        Write-Host '   SKIP - excluded in config.json' -ForegroundColor DarkGray
        Record-RepoTiming -Label $label -Policy $policy.Label -BranchCount 0 -StartedAt $repoStartedAt -Note 'excluded'
        continue
    }

    $head = Invoke-Git -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD') -WorkDir $repoPath
    if ($head.ExitCode -ne 0) {
        $repoErrors.Add("$label (not a valid git repo)")
        Write-Host '   SKIP - not a valid git repo' -ForegroundColor Red
        Record-RepoTiming -Label $label -Policy $policy.Label -BranchCount 0 -StartedAt $repoStartedAt -Note 'invalid repo'
        continue
    }
    $originalBranch = $head.Output
    $hadStash = $false
    $stashMessage = "novopay-branch-updater-$RunId-$($label -replace '[^a-zA-Z0-9_-]', '_')"

    try {
        if (Test-DirtyWorkingTree -WorkDir $repoPath) {
            $hadStash = Save-RepoWorktree -WorkDir $repoPath -RepoLabel $label -StashMessage $stashMessage
            if (-not $hadStash -and (Test-DirtyWorkingTree -WorkDir $repoPath)) {
                $skipped.Add("$label (dirty working tree and auto-stash failed - repo skipped)")
                Write-Host '   SKIP - dirty working tree, auto-stash failed' -ForegroundColor Red
                $timingNote = 'stash failed'
                continue
            }
        }

        $fetchAll = Invoke-Git -GitArguments @('fetch', '--all', '--prune') -WorkDir $repoPath
        if ($fetchAll.ExitCode -ne 0) {
            $repoErrors.Add("$label (fetch --all failed: $($fetchAll.Output -replace '\s+', ' '))")
            Write-Host '   WARN - fetch --all failed, continuing with per-branch fetch' -ForegroundColor DarkYellow
        }

        if ($policy.Type -eq 'all-local') {
            $branchesToUpdate = Get-LocalBranches -WorkDir $repoPath
            if ($branchesToUpdate.Count -eq 0) {
                $skipped.Add("$label (no local branches found)")
                Write-Host '   WARN - no local branches to update' -ForegroundColor DarkYellow
            }
            foreach ($branch in $branchesToUpdate) {
                $branchCount++
                Write-Host "   - $branch" -NoNewline
                $result = Update-Branch -WorkDir $repoPath -RepoLabel $label -Branch $branch -SkipPerBranchFetch
                Write-BranchResult -Result $result
            }
        }
        else {
            foreach ($branch in $policy.Branches) {
                $branchCount++
                Write-Host "   - $branch" -NoNewline
                $result = Update-Branch -WorkDir $repoPath -RepoLabel $label -Branch $branch
                Write-BranchResult -Result $result
            }
        }
    }
    finally {
        Restore-RepoWorktree -WorkDir $repoPath -RepoLabel $label -OriginalBranch $originalBranch -HadStash $hadStash
        Record-RepoTiming -Label $label -Policy $policy.Label -BranchCount $branchCount -StartedAt $repoStartedAt -Note $timingNote
    }
}

$finishedAt = Get-Date
$duration   = $finishedAt - $startedAt

$htmlReport = New-HtmlReport `
    -StartedAt $startedAt `
    -FinishedAt $finishedAt `
    -Duration $duration `
    -ReportPath $ReportPath `
    -RepoCount $repos.Count `
    -Policies $repoPolicies `
    -Excluded $excludedRepos `
    -ConflictItems $conflicts `
    -SkippedItems $skipped `
    -NotFoundItems $notFound `
    -ErrorItems $repoErrors `
    -UpdatedItems $updated `
    -StashEventItems $stashEvents `
    -StashFailedItems $stashFailed `
    -RepoTimingItems $repoTimings

$htmlReport | Set-Content -Path $ReportPath -Encoding UTF8

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' DONE' -ForegroundColor Cyan
Write-Host ' Opening report in browser (file removed when tab closes)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

if ($conflicts.Count -gt 0) {
    Write-Host 'Merge conflicts:' -ForegroundColor Red
    $conflicts | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
else {
    Write-Host 'No merge conflicts.' -ForegroundColor Green
}

Write-Host ''
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OpenReportScript -ReportPath $ReportPath
