param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,
    [Parameter(Mandatory = $true)]
    [string]$ToolRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [bool]$DryRun = $false,
    [string]$ProfileName = ''
)

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir 'Load-Config.ps1')
. (Join-Path $ScriptDir 'Git-Helpers.ps1')

$cfg = Get-NovopayBranchUpdaterConfig -ToolRoot $ToolRoot -ProfileName $ProfileName
$RootPath = $cfg.NovopayRoot
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

$result = [ordered]@{
    Label         = ''
    Policy        = ''
    BranchCount   = 0
    DurationText  = ''
    Note          = 'updated'
    Conflicts     = @()
    Skipped       = @()
    NotFound      = @()
    Updated       = @()
    RepoErrors    = @()
    Excluded      = @()
    PolicyLine    = ''
    StashEvents   = @()
    StashFailed   = @()
    ShaChanges    = @()
    PreflightIssues = @()
}

function Get-RepoLabel {
    param([string]$RepoPath)
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { return '(unknown)' }
    $normalizedRoot = $RootPath.TrimEnd('\', '/')
    $normalizedPath = $RepoPath.TrimEnd('\', '/')
    if ($normalizedPath -eq $normalizedRoot) { return '(root)' }
    if ($normalizedPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedPath.Substring($normalizedRoot.Length).TrimStart('\', '/')
    }
    return Split-Path -Leaf $RepoPath
}

function Get-RepoFolderName {
    param([string]$RepoPath)
    if ([string]::IsNullOrWhiteSpace($RepoPath)) { return '(unknown)' }
    $normalizedRoot = $RootPath.TrimEnd('\', '/')
    $normalizedPath = $RepoPath.TrimEnd('\', '/')
    if ($normalizedPath -eq $normalizedRoot) { return '(root)' }
    return Split-Path -Leaf $RepoPath
}

function Get-RepoPolicy {
    param([string]$RepoPath)

    $folder = Get-RepoFolderName -RepoPath $RepoPath
    if ($cfg.ExcludedRepos -contains $folder) {
        return @{ Type = 'skip'; Label = 'excluded by config' }
    }
    if ($cfg.AllLocalBranchesRepos -contains $folder) {
        return @{ Type = 'all-local'; Label = 'all local branches' }
    }
    if ($cfg.FrontendRepos -contains $folder) {
        return @{ Type = 'list'; Branches = $cfg.FrontendBranches; Label = 'frontend (dsa branches)' }
    }
    return @{ Type = 'list'; Branches = $cfg.BackendBranches; Label = 'backend (ddp branches)' }
}

function Get-LocalBranches {
    param([string]$WorkDir)
    $r = Invoke-Git -GitArguments @('branch', '--format=%(refname:short)') -WorkDir $WorkDir
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return @() }
    return $r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$startedAt = Get-Date
$label = Get-RepoLabel -RepoPath $RepoPath
$policy = Get-RepoPolicy -RepoPath $RepoPath
$result.Label = $label
$result.Policy = $policy.Label
$result.PolicyLine = "$label -> $($policy.Label)"

$conflicts = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$notFound = [System.Collections.Generic.List[string]]::new()
$updated = [System.Collections.Generic.List[string]]::new()
$repoErrors = [System.Collections.Generic.List[string]]::new()
$stashEvents = [System.Collections.Generic.List[string]]::new()
$stashFailed = [System.Collections.Generic.List[string]]::new()
$shaChanges = [System.Collections.Generic.List[string]]::new()

Write-Output ">> $label [$($policy.Label)]"

if ($policy.Type -eq 'skip') {
    $result.Excluded = @("$label (skipped - excluded in config)")
    $result.Note = 'excluded'
    Write-Output '   SKIP - excluded in config'
}
else {
    $head = Invoke-Git -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD') -WorkDir $RepoPath
    if ($head.ExitCode -ne 0) {
        if (Test-Path (Join-Path $RepoPath '.git')) {
            $repoErrors.Add("$label (empty repo - no commits on HEAD)")
            $result.Note = 'empty repo'
            Write-Output '   SKIP - empty repo (no commits on HEAD)'
        }
        else {
            $repoErrors.Add("$label (not a valid git repo)")
            $result.Note = 'invalid repo'
            Write-Output '   SKIP - not a valid git repo'
        }
    }
    else {
        if ($cfg.PreflightChecks) {
            $repoPreflight = Invoke-RepoPreflight -WorkDir $RepoPath -RepoLabel $label -CheckOrigin:(-not $DryRun)
            foreach ($issue in $repoPreflight) {
                $result.PreflightIssues += $issue
                $repoErrors.Add($issue)
            }
            if ($repoPreflight.Count -gt 0) {
                $result.Note = 'preflight failed'
                Write-Output '   SKIP - preflight failed'
            }
        }

        if ($result.Note -eq 'updated') {
            $originalBranch = $head.Output
            $hadStash = $false
            $stashMessage = "novopay-branch-updater-$RunId-$($label -replace '[^a-zA-Z0-9_-]', '_')"

            try {
                if (-not $DryRun -and (Test-DirtyWorkingTree -WorkDir $RepoPath)) {
                    $stash = Invoke-Git -GitArguments @('stash', 'push', '-u', '-m', $stashMessage) -WorkDir $RepoPath
                    if ($stash.ExitCode -eq 0 -and $stash.Output -notmatch 'No local changes to save') {
                        $hadStash = $true
                        $stashEvents.Add("$label (stashed uncommitted changes before fetch)")
                        Write-Output '   Stashed uncommitted changes'
                    }
                    elseif (Test-DirtyWorkingTree -WorkDir $RepoPath) {
                        $repoErrors.Add("$label (dirty working tree and auto-stash failed)")
                        $result.Note = 'stash failed'
                        Write-Output '   SKIP - dirty working tree, auto-stash failed'
                    }
                }

                if ($result.Note -eq 'updated') {
                    if (-not $DryRun) {
                        $fetchAll = Invoke-Git -GitArguments @('fetch', '--all', '--prune') -WorkDir $RepoPath
                        if ($fetchAll.ExitCode -ne 0) {
                            $repoErrors.Add("$label (fetch --all failed: $($fetchAll.Output -replace '\s+', ' '))")
                            Write-Output '   WARN - fetch --all failed'
                        }
                    }

                    $branches = if ($policy.Type -eq 'all-local') { Get-LocalBranches -WorkDir $RepoPath } else { @($policy.Branches) }
                    if ($branches.Count -eq 0) {
                        $skipped.Add("$label (no branches to update)")
                    }

                    foreach ($branch in $branches) {
                        $result.BranchCount++
                        $branchResult = Update-BranchWithStrategy `
                            -WorkDir $RepoPath `
                            -RepoLabel $label `
                            -Branch $branch `
                            -SkipPerBranchFetch:($policy.Type -eq 'all-local') `
                            -PreferFastForward $cfg.PreferFastForward `
                            -AllowMergeOnDivergence $cfg.AllowMergeOnDivergence `
                            -SkipIfLocalAhead $cfg.SkipIfLocalAhead `
                            -DryRun $DryRun `
                            -Conflicts $conflicts `
                            -Skipped $skipped `
                            -NotFound $notFound `
                            -Updated $updated `
                            -ShaChanges $shaChanges

                        Write-Output "   - $branch -> $branchResult"
                    }
                }
            }
            finally {
                if (-not $DryRun) {
                    if ($originalBranch -and $originalBranch -ne 'HEAD') {
                        Invoke-Git -GitArguments @('checkout', $originalBranch) -WorkDir $RepoPath | Out-Null
                    }
                    if ($hadStash) {
                        $pop = Invoke-Git -GitArguments @('stash', 'pop') -WorkDir $RepoPath
                        if ($pop.ExitCode -ne 0) {
                            $stashFailed.Add("$label (failed to restore stash on $originalBranch)")
                        }
                        else {
                            $stashEvents.Add("$label (restored uncommitted changes on $originalBranch, stash deleted)")
                            Write-Output "   Restored uncommitted changes on $originalBranch"
                        }
                    }
                }
            }
        }
    }
}

$duration = (Get-Date) - $startedAt
if ($duration.TotalHours -ge 1) { $durText = $duration.ToString('h\:mm\:ss') }
elseif ($duration.TotalSeconds -ge 60) { $durText = $duration.ToString('m\:ss') }
else { $durText = ('{0:N1}s' -f $duration.TotalSeconds) }

$result.DurationText = $durText
$result.Conflicts = @($conflicts)
$result.Skipped = @($skipped)
$result.NotFound = @($notFound)
$result.Updated = @($updated)
$result.RepoErrors = @($repoErrors)
$result.StashEvents = @($stashEvents)
$result.StashFailed = @($stashFailed)
$result.ShaChanges = @($shaChanges)
$result.DurationSeconds = $duration.TotalSeconds

Write-Output "   Time: $durText for $($result.BranchCount) branch(es)"

return [pscustomobject]$result
