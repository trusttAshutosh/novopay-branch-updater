function Escape-Html {
    param([string]$Text)
    if (-not $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-DurationSpan {
    param([timespan]$Duration)
    if ($Duration.TotalHours -ge 1) { return $Duration.ToString('h\:mm\:ss') }
    if ($Duration.TotalSeconds -ge 60) { return $Duration.ToString('m\:ss') }
    return ('{0:N1}s' -f $Duration.TotalSeconds)
}

function New-HtmlListRows {
    param(
        [array]$Items,
        [string]$RowClass = ''
    )
    if (-not $Items -or $Items.Count -eq 0) {
        return "<tr><td class='empty' colspan='2'>(none)</td></tr>"
    }
    $rows = @()
    $i = 0
    foreach ($item in $Items) {
        $i++
        $classAttr = if ($RowClass) { " class='$RowClass'" } else { '' }
        $rows += "<tr$classAttr><td class='num'>$i</td><td>$(Escape-Html ([string]$item))</td></tr>"
    }
    return $rows -join "`n"
}

function New-HtmlRepoTimingRows {
    param([array]$Timings)

    if (-not $Timings -or $Timings.Count -eq 0) {
        return "<tr><td class='empty' colspan='6'>(none)</td></tr>"
    }

    $rows = @()
    $i = 0
    foreach ($item in ($Timings | Sort-Object DurationSeconds -Descending)) {
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

function New-BranchUpdaterReport {
    param(
        [pscustomobject]$Data
    )

    $conflictCount = $Data.Conflicts.Count
    $statusClass = if ($conflictCount -gt 0) { 'warn' } else { 'ok' }
    $statusLabel = if ($Data.DryRun) {
        "Dry run - no changes made"
    }
    elseif ($conflictCount -gt 0) {
        "$conflictCount merge conflict(s)"
    }
    else {
        'All branches updated cleanly'
    }

    $slowest = $Data.RepoTimings | Sort-Object DurationSeconds -Descending | Select-Object -First 1
    $slowestText = if ($slowest) {
        "$(Escape-Html $slowest.Label) - $(Escape-Html $slowest.DurationText) ($($slowest.BranchCount) branches)"
    }
    else { '(none)' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Novopay Branch Update Report</title>
  <style>
    :root { --bg:#f4f6f8; --card:#fff; --text:#1a1a2e; --muted:#5c6370; --border:#dde3ea; --ok:#0f7b3c; --ok-bg:#e8f5ee; --warn:#b45309; --warn-bg:#fef3c7; --bad:#b91c1c; --bad-bg:#fee2e2; --info:#1d4ed8; }
    body { margin:0; font-family:"Segoe UI",Tahoma,sans-serif; background:var(--bg); color:var(--text); line-height:1.5; }
    .wrap { max-width:1100px; margin:0 auto; padding:24px 20px 48px; }
    header { background:linear-gradient(135deg,#0f172a,#1e3a5f); color:#fff; border-radius:12px; padding:28px 32px; margin-bottom:24px; }
    header h1 { margin:0 0 8px; font-size:1.75rem; }
    header p { margin:4px 0; color:#cbd5e1; font-size:0.95rem; }
    .status-pill { display:inline-block; margin-top:12px; padding:6px 12px; border-radius:999px; font-weight:600; }
    .status-pill.ok { background:var(--ok-bg); color:var(--ok); }
    .status-pill.warn { background:var(--warn-bg); color:var(--warn); }
    .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:14px; margin-bottom:24px; }
    .stat { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:16px; text-align:center; }
    .stat .value { font-size:1.8rem; font-weight:700; }
    .stat .label { color:var(--muted); font-size:0.85rem; margin-top:4px; }
    .stat.ok .value { color:var(--ok); } .stat.bad .value { color:var(--bad); } .stat.warn .value { color:var(--warn); } .stat.info .value { color:var(--info); }
    section { background:var(--card); border:1px solid var(--border); border-radius:10px; margin-bottom:18px; overflow:hidden; }
    section h2 { margin:0; padding:14px 18px; font-size:1.05rem; border-bottom:1px solid var(--border); background:#f8fafc; }
    section h2.conflict { background:var(--bad-bg); color:var(--bad); }
    section h2.success { background:var(--ok-bg); color:var(--ok); }
    .content { padding:16px 18px; }
    table { width:100%; border-collapse:collapse; font-size:0.92rem; }
    th,td { padding:10px 12px; border-bottom:1px solid var(--border); text-align:left; vertical-align:top; }
    th { background:#f8fafc; color:var(--muted); font-weight:600; }
    tr.conflict td { background:var(--bad-bg); } tr.success td { background:#f8fffb; }
    td.empty { color:var(--muted); font-style:italic; } td.num { color:var(--muted); width:48px; }
    .timing-summary { margin:0 0 12px; color:var(--muted); }
    .meta-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:10px 18px; font-size:0.92rem; }
    .meta-grid dt { color:var(--muted); margin:0; } .meta-grid dd { margin:0 0 8px; font-weight:600; }
    footer { margin-top:20px; color:var(--muted); font-size:0.82rem; text-align:center; }
  </style>
</head>
<body>
  <div class="wrap">
    <header>
      <h1>Novopay Branch Update Report</h1>
      <p>Generated: $(Escape-Html $Data.FinishedAt.ToString('yyyy-MM-dd HH:mm:ss'))</p>
      <p>Duration: $(Escape-Html $Data.Duration.ToString('hh\:mm\:ss'))</p>
      <p>Root: $(Escape-Html $Data.NovopayRoot)</p>
      <p>Profile: $(Escape-Html $Data.Profile) | Parallel: $($Data.MaxParallel) | Dry run: $($Data.DryRun)</p>
      <span class="status-pill $statusClass">$statusLabel</span>
    </header>
    <div class="stats">
      <div class="stat info"><div class="value">$($Data.RepoCount)</div><div class="label">Repos scanned</div></div>
      <div class="stat ok"><div class="value">$($Data.Updated.Count)</div><div class="label">Updated OK</div></div>
      <div class="stat bad"><div class="value">$conflictCount</div><div class="label">Merge conflicts</div></div>
      <div class="stat warn"><div class="value">$($Data.Skipped.Count)</div><div class="label">Skipped</div></div>
      <div class="stat"><div class="value">$($Data.ShaChanges.Count)</div><div class="label">SHA changes</div></div>
    </div>
    <section><h2>Repo update timing</h2><div class="content"><p class="timing-summary">Slowest: $slowestText</p>
      <table><thead><tr><th>#</th><th>Repo</th><th>Policy</th><th>Branches</th><th>Duration</th><th>Status</th></tr></thead>
      <tbody>$(New-HtmlRepoTimingRows -Timings $Data.RepoTimings)</tbody></table></div></section>
    <section><h2 class="success">SHA changes</h2><div class="content">
      <table><thead><tr><th>#</th><th>Repo / branch</th></tr></thead>
      <tbody>$(New-HtmlListRows -Items $Data.ShaChanges -RowClass 'success')</tbody></table></div></section>
    <section><h2 class="conflict">Merge conflicts</h2><div class="content">
      <table><thead><tr><th>#</th><th>Detail</th></tr></thead>
      <tbody>$(New-HtmlListRows -Items $Data.Conflicts -RowClass 'conflict')</tbody></table></div></section>
    <section><h2>Skipped</h2><div class="content">
      <table><thead><tr><th>#</th><th>Detail</th></tr></thead>
      <tbody>$(New-HtmlListRows -Items $Data.Skipped)</tbody></table></div></section>
    <section><h2>Preflight / repo errors</h2><div class="content">
      <table><thead><tr><th>#</th><th>Detail</th></tr></thead>
      <tbody>$(New-HtmlListRows -Items $Data.RepoErrors)</tbody></table></div></section>
    <section><h2 class="success">Successfully updated</h2><div class="content">
      <table><thead><tr><th>#</th><th>Detail</th></tr></thead>
      <tbody>$(New-HtmlListRows -Items $Data.Updated -RowClass 'success')</tbody></table></div></section>
    <footer>Report: $(Escape-Html $Data.ReportPath)</footer>
  </div>
</body>
</html>
"@

    $json = @{
        generatedAt   = $Data.FinishedAt.ToString('o')
        duration      = $Data.Duration.ToString()
        novopayRoot   = $Data.NovopayRoot
        profile       = $Data.Profile
        dryRun        = $Data.DryRun
        maxParallel   = $Data.MaxParallel
        repoCount     = $Data.RepoCount
        conflicts     = @($Data.Conflicts)
        skipped       = @($Data.Skipped)
        notFound      = @($Data.NotFound)
        updated       = @($Data.Updated)
        repoErrors    = @($Data.RepoErrors)
        shaChanges    = @($Data.ShaChanges)
        stashEvents   = @($Data.StashEvents)
        stashFailed   = @($Data.StashFailed)
        repoTimings   = @($Data.RepoTimings | ForEach-Object {
            @{
                label = $_.Label
                policy = $_.Policy
                branchCount = $_.BranchCount
                durationSeconds = $_.DurationSeconds
                durationText = $_.DurationText
                note = $_.Note
            }
        })
    }

    return [pscustomobject]@{
        Html = $html
        Json = ($json | ConvertTo-Json -Depth 6)
    }
}
