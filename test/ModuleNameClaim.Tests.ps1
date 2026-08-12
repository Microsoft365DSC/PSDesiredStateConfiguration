BeforeAll {
    $script:PSDscTestRoot = $PSScriptRoot
    $script:PSDscRepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PSDscCompatRoot = Join-Path $script:PSDscRepoRoot 'M365DSC.PSDesiredStateConfiguration\Compat'

    # The claim has to hold for a consumer that only imports the engine by path, so this
    # suite runs out of process with the Compat folder removed from PSModulePath again.
    # In-process assertions would pass on the path entry the other suites add themselves.
    $script:PSDscProbeScript = Join-Path $TestDrive 'probe-name-claim.ps1'
    Set-Content -Path $script:PSDscProbeScript -Encoding UTF8 -Value @'
param
(
    [string] $Repo,
    [string] $Out
)

$separator = [System.IO.Path]::PathSeparator
$compatRoot = Join-Path $Repo 'M365DSC.PSDesiredStateConfiguration\Compat'
$env:PSModulePath = (@($env:PSModulePath -split $separator) |
    Where-Object { $_ -and $_ -ne $compatRoot }) -join $separator
$env:PSModulePath = (Join-Path $Repo 'test\TestModules') + $separator + $env:PSModulePath
$pathBeforeImport = $env:PSModulePath

Import-Module (Join-Path $Repo 'M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1') -Force

$configurationText = @(
    'configuration NameClaimCfg'
    '{'
    '    Import-DscResource -ModuleName xTestClassResource'
    '    Node localhost'
    '    {'
    '        ResourceForTests1 a'
    '        {'
    "            Prop1 = 'claim'"
    '        }'
    '    }'
    '}'
) -join [Environment]::NewLine

Invoke-Expression $configurationText
$null = NameClaimCfg -OutputPath (Join-Path $Out 'first')

# A second compile is the regression that matters: the foreign module the prologue used to
# pull in owned Configuration from the first compile onwards.
Invoke-Expression ($configurationText -replace 'NameClaimCfg', 'NameClaimCfg2')
$null = NameClaimCfg2 -OutputPath (Join-Path $Out 'second')

$claimed = @(Get-Module -Name 'PSDesiredStateConfiguration')
$result = [ordered]@{
    EngineInstances     = @(Get-Module -Name 'M365DSC.PSDesiredStateConfiguration').Count
    ClaimedPaths        = @($claimed | ForEach-Object { $_.Path })
    ClaimedVersions     = @($claimed | ForEach-Object { $_.Version.ToString() })
    ConfigurationOwner  = (Get-Command -Name 'Configuration').ScriptBlock.Module.Name
    ResourceCmdletOwner = (Get-Command -Name 'Get-DscResource').ScriptBlock.Module.Name
    SecondMofExists     = Test-Path -LiteralPath (Join-Path $Out 'second\localhost.mof')
}

Remove-Module -Name 'M365DSC.PSDesiredStateConfiguration' -Force
$result['PSModulePathRestored'] = ($env:PSModulePath -eq $pathBeforeImport)
$result['ModulesLeft'] = @((Get-Module).Name | Where-Object { $_ -match 'DesiredState' })

$result | ConvertTo-Json -Compress
'@

    $shell = (Get-Process -Id $PID).Path
    $output = & $shell -NoProfile -NonInteractive -File $script:PSDscProbeScript -Repo $script:PSDscRepoRoot -Out (Join-Path $TestDrive 'mof')
    $script:PSDscClaim = ($output | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
}

Describe 'Engine imported by path only' {
    It 'loads a single engine instance' {
        $script:PSDscClaim.EngineInstances | Should -Be 1
    }

    It 'claims the PSDesiredStateConfiguration name with the shipped compatibility module' {
        @($script:PSDscClaim.ClaimedPaths).Count | Should -Be 1
        $script:PSDscClaim.ClaimedPaths[0] | Should -BeLike '*Compat\PSDesiredStateConfiguration\PSDesiredStateConfiguration.psm1'
    }

    It 'never loads the inbox 1.1 or gallery 2.x module' {
        $script:PSDscClaim.ClaimedVersions | Should -Not -Contain '1.1'
        foreach ($version in @($script:PSDscClaim.ClaimedVersions))
        {
            ([version]$version).Major | Should -BeGreaterOrEqual 3
        }
    }

    It 'keeps the exported commands owned by the engine after two compiles' {
        $script:PSDscClaim.ConfigurationOwner | Should -Be 'M365DSC.PSDesiredStateConfiguration'
        $script:PSDscClaim.ResourceCmdletOwner | Should -Be 'M365DSC.PSDesiredStateConfiguration'
        $script:PSDscClaim.SecondMofExists | Should -Be $true
    }

    It 'restores PSModulePath and drops the compatibility module on Remove-Module' {
        $script:PSDscClaim.PSModulePathRestored | Should -Be $true
        @($script:PSDscClaim.ModulesLeft).Count | Should -Be 0
    }
}
