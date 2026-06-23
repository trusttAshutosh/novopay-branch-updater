function Expand-ConfigString {
    param([string]$Value)

    if (-not $Value) {
        return $Value
    }

    $expanded = $Value
    $expanded = $expanded -replace '\$\{USERPROFILE\}', $env:USERPROFILE
    $expanded = $expanded -replace '\$env:USERPROFILE', $env:USERPROFILE
    return $expanded
}

function Merge-ConfigObject {
    param(
        $Base,
        $Override
    )

    if ($null -eq $Override) {
        return $Base
    }

    if ($Base -is [System.Collections.IList] -and $Override -is [System.Collections.IList]) {
        return @($Override)
    }

    if ($Base -is [psobject] -and $Override -is [psobject]) {
        $result = @{}
        foreach ($prop in $Base.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value
        }
        foreach ($prop in $Override.PSObject.Properties) {
            if ($prop.Name -eq '_comment') {
                continue
            }
            if ($result.ContainsKey($prop.Name) -and $result[$prop.Name] -is [psobject] -and $prop.Value -is [psobject]) {
                $result[$prop.Name] = Merge-ConfigObject -Base $result[$prop.Name] -Override $prop.Value
            }
            else {
                $result[$prop.Name] = $prop.Value
            }
        }
        return [pscustomobject]$result
    }

    return $Override
}

function Get-NovopayBranchUpdaterConfig {
    param(
        [string]$ToolRoot,
        [string]$ProfileName = ''
    )

    $configPath = Join-Path $ToolRoot 'config.json'
    $localConfigPath = Join-Path $ToolRoot 'config.local.json'

    if (-not (Test-Path $configPath)) {
        throw "Config not found: $configPath"
    }

    $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (Test-Path $localConfigPath) {
        $localConfig = Get-Content -Path $localConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config = Merge-ConfigObject -Base $config -Override $localConfig
    }

    $activeProfile = if ($ProfileName) { $ProfileName } else { $config.defaultProfile }
    if ($activeProfile -and $config.profiles -and $config.profiles.PSObject.Properties.Name -contains $activeProfile) {
        $profileOverride = $config.profiles.$activeProfile
        if ($profileOverride -and ($profileOverride.PSObject.Properties | Measure-Object).Count -gt 0) {
            $config = Merge-ConfigObject -Base $config -Override $profileOverride
        }
    }

    $defaultNovopayRoot = (Resolve-Path (Join-Path $ToolRoot '..\..')).Path
    $rootFromEnv = $null
    if ($config.novopayRootEnv) {
        $rootFromEnv = [Environment]::GetEnvironmentVariable($config.novopayRootEnv)
    }

    $novopayRoot = if ($rootFromEnv) {
        $rootFromEnv
    }
    elseif ($config.novopayRoot) {
        Expand-ConfigString -Value $config.novopayRoot
    }
    else {
        $defaultNovopayRoot
    }

    if (-not (Test-Path $novopayRoot)) {
        throw "Novopay root not found: $novopayRoot. Set novopayRoot in config.local.json or $($config.novopayRootEnv) env var."
    }

    $reportDirectory = if ($config.reportDirectory) {
        Expand-ConfigString -Value $config.reportDirectory
    }
    else {
        Join-Path $ToolRoot '.reports'
    }

    if (-not (Test-Path $reportDirectory)) {
        New-Item -Path $reportDirectory -ItemType Directory | Out-Null
    }

    $execution = if ($config.execution) { $config.execution } else { [pscustomobject]@{} }
    $reportCfg = if ($config.report) { $config.report } else { [pscustomobject]@{} }

    return [pscustomobject]@{
        ToolRoot               = $ToolRoot
        NovopayRoot            = (Resolve-Path $novopayRoot).Path
        ReportDirectory        = $reportDirectory
        ReportFileName         = $config.reportFileName
        ReportPath             = Join-Path $reportDirectory $config.reportFileName
        ReportJsonPath         = Join-Path $reportDirectory ($config.reportFileName -replace '\.html$', '.json')
        ActiveProfile          = $activeProfile
        Scheduler              = $config.scheduler
        FrontendRepos          = @($config.frontend.repos)
        FrontendBranches       = @($config.frontend.branches)
        BackendBranches        = @($config.backend.branches)
        AllLocalBranchesRepos  = @($config.allLocalBranchesRepos)
        ExcludedRepos          = @($config.excludedRepos)
        PreferredRepoOrder     = @($config.preferredRepoOrder)
        MaxParallelRepos       = if ($execution.maxParallelRepos) { [int]$execution.maxParallelRepos } else { 1 }
        PreferFastForward      = if ($null -ne $execution.preferFastForward) { [bool]$execution.preferFastForward } else { $true }
        AllowMergeOnDivergence = if ($null -ne $execution.allowMergeOnDivergence) { [bool]$execution.allowMergeOnDivergence } else { $true }
        SkipIfLocalAhead       = if ($null -ne $execution.skipIfLocalAhead) { [bool]$execution.skipIfLocalAhead } else { $true }
        PreflightChecks        = if ($null -ne $execution.preflightChecks) { [bool]$execution.preflightChecks } else { $true }
        MinFreeDiskGb          = if ($execution.minFreeDiskGb) { [double]$execution.minFreeDiskGb } else { 1 }
        WriteJson              = if ($null -ne $reportCfg.writeJson) { [bool]$reportCfg.writeJson } else { $true }
        KeepReport             = if ($null -ne $reportCfg.keepReport) { [bool]$reportCfg.keepReport } else { $false }
        NotifyOnFailure        = if ($null -ne $reportCfg.notifyOnFailure) { [bool]$reportCfg.notifyOnFailure } else { $true }
    }
}
