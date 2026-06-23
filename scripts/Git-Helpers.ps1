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

function Get-GitShortSha {
    param(
        [string]$WorkDir,
        [string]$Ref
    )
    if (-not (Test-GitRef -WorkDir $WorkDir -Ref $Ref)) {
        return $null
    }
    $r = Invoke-Git -GitArguments @('rev-parse', '--short', $Ref) -WorkDir $WorkDir
    if ($r.ExitCode -ne 0) { return $null }
    return $r.Output
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

function Test-GitIndexLocked {
    param([string]$WorkDir)
    return Test-Path (Join-Path $WorkDir '.git\index.lock')
}

function Test-GitInProgressState {
    param([string]$WorkDir)

    if (Test-Path (Join-Path $WorkDir '.git\MERGE_HEAD')) { return 'merge in progress' }
    if (Test-Path (Join-Path $WorkDir '.git\REBASE_HEAD')) { return 'rebase in progress' }
    if (Test-Path (Join-Path $WorkDir '.git\CHERRY_PICK_HEAD')) { return 'cherry-pick in progress' }
    return $null
}

function Test-OriginReachable {
    param([string]$WorkDir)

    $r = Invoke-Git -GitArguments @('ls-remote', '--heads', 'origin') -WorkDir $WorkDir
    return $r.ExitCode -eq 0
}

function Get-BranchAheadBehind {
    param(
        [string]$WorkDir,
        [string]$Branch
    )

    if (-not (Test-GitRef -WorkDir $WorkDir -Ref $Branch)) {
        return @{ Ahead = 0; Behind = 0 }
    }
    if (-not (Test-GitRef -WorkDir $WorkDir -Ref "origin/$Branch")) {
        return @{ Ahead = 0; Behind = 0 }
    }

    $ahead = Invoke-Git -GitArguments @('rev-list', '--count', "origin/$Branch..$Branch") -WorkDir $WorkDir
    $behind = Invoke-Git -GitArguments @('rev-list', '--count', "$Branch..origin/$Branch") -WorkDir $WorkDir
    return @{
        Ahead  = if ($ahead.ExitCode -eq 0) { [int]$ahead.Output } else { 0 }
        Behind = if ($behind.ExitCode -eq 0) { [int]$behind.Output } else { 0 }
    }
}

function Invoke-PreflightChecks {
    param(
        [string]$NovopayRoot,
        [double]$MinFreeDiskGb
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $drive = (Split-Path -Qualifier $NovopayRoot).TrimEnd(':')
    $disk = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
    if ($disk -and $disk.Free -lt ($MinFreeDiskGb * 1GB)) {
        $issues.Add("Low disk space on ${drive}: ($([math]::Round($disk.Free / 1GB, 1)) GB free, need $MinFreeDiskGb GB)")
    }
    return $issues
}

function Invoke-RepoPreflight {
    param(
        [string]$WorkDir,
        [string]$RepoLabel,
        [bool]$CheckOrigin
    )

    $issues = [System.Collections.Generic.List[string]]::new()

    if (Test-GitIndexLocked -WorkDir $WorkDir) {
        $issues.Add("$RepoLabel (index.lock present - another git process may be running)")
    }

    $inProgress = Test-GitInProgressState -WorkDir $WorkDir
    if ($inProgress) {
        $issues.Add("$RepoLabel ($inProgress)")
    }

    if ($CheckOrigin -and -not (Test-OriginReachable -WorkDir $WorkDir)) {
        $issues.Add("$RepoLabel (origin not reachable)")
    }

    return $issues
}

function Update-BranchWithStrategy {
    param(
        [string]$WorkDir,
        [string]$RepoLabel,
        [string]$Branch,
        [bool]$SkipPerBranchFetch,
        [bool]$PreferFastForward,
        [bool]$AllowMergeOnDivergence,
        [bool]$SkipIfLocalAhead,
        [bool]$DryRun,
        [System.Collections.Generic.List[string]]$Conflicts,
        [System.Collections.Generic.List[string]]$Skipped,
        [System.Collections.Generic.List[string]]$NotFound,
        [System.Collections.Generic.List[string]]$Updated,
        [System.Collections.Generic.List[string]]$ShaChanges
    )

    $entry = "$RepoLabel / $Branch"
    $localRef = Test-GitRef -WorkDir $WorkDir -Ref $Branch
    $remoteRef = Test-GitRef -WorkDir $WorkDir -Ref "origin/$Branch"

    if (-not $localRef -and -not $remoteRef) {
        $NotFound.Add("$entry (branch not on local or origin)")
        return 'not-found'
    }

    if ($DryRun) {
        if (-not $remoteRef) {
            $NotFound.Add("$entry (no origin/$Branch)")
            return 'not-found'
        }
        $beforeSha = Get-GitShortSha -WorkDir $WorkDir -Ref $Branch
        $remoteSha = Get-GitShortSha -WorkDir $WorkDir -Ref "origin/$Branch"
        $ab = Get-BranchAheadBehind -WorkDir $WorkDir -Branch $Branch
        if ($localRef -and $SkipIfLocalAhead -and $ab.Ahead -gt 0) {
            $Skipped.Add("$entry (dry-run: local ahead by $($ab.Ahead) commit(s), would skip)")
            return 'skipped'
        }
        if ($beforeSha -eq $remoteSha) {
            $Updated.Add("$entry (dry-run: already up to date $beforeSha)")
        }
        elseif ($ab.Behind -gt 0 -and $ab.Ahead -eq 0) {
            $Updated.Add("$entry (dry-run: would fast-forward $beforeSha -> $remoteSha)")
        }
        else {
            $Updated.Add("$entry (dry-run: would merge $beforeSha -> $remoteSha)")
        }
        return 'ok'
    }

    if ($localRef) {
        $checkout = Invoke-Git -GitArguments @('checkout', $Branch) -WorkDir $WorkDir
    }
    else {
        $checkout = Invoke-Git -GitArguments @('checkout', '-B', $Branch, "origin/$Branch") -WorkDir $WorkDir
    }

    if ($checkout.ExitCode -ne 0) {
        $Skipped.Add("$entry (checkout failed: $($checkout.Output -replace '\s+', ' '))")
        return 'skipped'
    }

    if (-not $SkipPerBranchFetch) {
        $fetch = Invoke-Git -GitArguments @('fetch', 'origin', $Branch) -WorkDir $WorkDir
        if ($fetch.ExitCode -ne 0) {
            $Skipped.Add("$entry (fetch failed: $($fetch.Output -replace '\s+', ' '))")
            return 'skipped'
        }
    }

    if (-not (Test-GitRef -WorkDir $WorkDir -Ref "origin/$Branch")) {
        $NotFound.Add("$entry (no origin/$Branch after fetch)")
        return 'not-found'
    }

    $beforeSha = Get-GitShortSha -WorkDir $WorkDir -Ref $Branch
    $remoteSha = Get-GitShortSha -WorkDir $WorkDir -Ref "origin/$Branch"
    $ab = Get-BranchAheadBehind -WorkDir $WorkDir -Branch $Branch

    if ($SkipIfLocalAhead -and $ab.Ahead -gt 0) {
        $Skipped.Add("$entry (local ahead by $($ab.Ahead) commit(s) - skipped)")
        return 'skipped'
    }

    if ($beforeSha -eq $remoteSha) {
        $Updated.Add("$entry (already up to date $beforeSha)")
        return 'ok'
    }

    $mergeResult = $null
    if ($PreferFastForward -and $ab.Ahead -eq 0) {
        $mergeResult = Invoke-Git -GitArguments @('merge', '--ff-only', "origin/$Branch") -WorkDir $WorkDir
    }
    elseif ($AllowMergeOnDivergence) {
        $mergeResult = Invoke-Git -GitArguments @('merge', '--no-edit', "origin/$Branch") -WorkDir $WorkDir
    }
    else {
        $Skipped.Add("$entry (diverged and merge not allowed)")
        return 'skipped'
    }

    if ($mergeResult.ExitCode -ne 0 -and $PreferFastForward -and $AllowMergeOnDivergence -and $ab.Ahead -eq 0) {
        $mergeResult = Invoke-Git -GitArguments @('merge', '--no-edit', "origin/$Branch") -WorkDir $WorkDir
    }

    if ($mergeResult.ExitCode -ne 0) {
        Abort-InProgressGitOps -WorkDir $WorkDir
        $Conflicts.Add($entry)
        return 'conflict'
    }

    $afterSha = Get-GitShortSha -WorkDir $WorkDir -Ref $Branch
    $ShaChanges.Add("$entry : $beforeSha -> $afterSha")
    if ($mergeResult.Output -match 'Already up to date') {
        $Updated.Add("$entry (already up to date $afterSha)")
    }
    elseif ($mergeResult.Output -match 'Fast-forward') {
        $Updated.Add("$entry (fast-forward $beforeSha -> $afterSha)")
    }
    else {
        $Updated.Add("$entry (merged $beforeSha -> $afterSha)")
    }
    return 'ok'
}
