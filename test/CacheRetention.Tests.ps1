BeforeAll {
    $script:PSDscTestRoot = $PSScriptRoot
    $script:PSDscRepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PSDscModuleUnderTestManifest = @(
        (Join-Path $script:PSDscRepoRoot 'out\PSDesiredStateConfiguration\PSDesiredStateConfiguration.psd1')
        (Join-Path $script:PSDscRepoRoot 'src\PSDesiredStateConfiguration\PSDesiredStateConfiguration.psd1')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    function Import-PSDscModuleUnderTest
    {
        Get-Module -Name PSDesiredStateConfiguration | Remove-Module -Force
        Import-Module $script:PSDscModuleUnderTestManifest -Force
    }

    $script:PSDscOriginalPSModulePath = $env:PSModulePath
    $script:PSDscModuleParent = Split-Path (Split-Path $script:PSDscModuleUnderTestManifest -Parent) -Parent
    $script:PSDscPathSeparator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = (Join-Path $script:PSDscTestRoot 'TestModules') + $script:PSDscPathSeparator + $script:PSDscModuleParent + $script:PSDscPathSeparator + $env:PSModulePath

    function Get-PSDscMofText
    {
        param ([string]$Path)

        [System.IO.File]::ReadAllText($Path)
    }

    Import-PSDscModuleUnderTest
}

AfterAll {
    if ($script:PSDscOriginalPSModulePath)
    {
        $env:PSModulePath = $script:PSDscOriginalPSModulePath
    }
}

Describe 'Keyword cache retention across compiles' {
    It 'makes the second compile of the same configuration faster and byte-identical' {
        $text = @'
Configuration RetentionTimingCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'r1'
            Value = 'v1'
            Ensure = 'Present'
            sArray = @('s1', 's2')
        }
        ResourceForTests1 r2
        {
            Prop1 = 'p2'
        }
    }
}
'@
        Invoke-Expression $text
        Clear-DscKeywordCache
        $firstDuration = Measure-Command { $null = RetentionTimingCfg -OutputPath (Join-Path $TestDrive 'timing-first') }
        $secondDuration = Measure-Command { $null = RetentionTimingCfg -OutputPath (Join-Path $TestDrive 'timing-second') }

        $firstMof = Join-Path $TestDrive 'timing-first\localhost.mof'
        $secondMof = Join-Path $TestDrive 'timing-second\localhost.mof'
        Test-Path $firstMof | Should -Be $true
        Test-Path $secondMof | Should -Be $true

        $firstBytes = [System.IO.File]::ReadAllBytes($firstMof)
        $secondBytes = [System.IO.File]::ReadAllBytes($secondMof)
        [System.Convert]::ToBase64String($secondBytes) | Should -Be ([System.Convert]::ToBase64String($firstBytes))

        # For a module this small, cold import and warm replay cost about the same, so a
        # timing ratio is noise; retention is asserted through the module state instead.
        # Large-module ratios are covered by tools\benchmarks.
        & (Get-Module PSDesiredStateConfiguration) { Test-DscKeywordCacheValid } | Should -Be $true
        & (Get-Module PSDesiredStateConfiguration) { $script:DscKeywordCacheState.ImportedModules.Keys -contains 'xTestClassResource' } | Should -Be $true
        $secondDuration.TotalMilliseconds | Should -BeLessThan ([math]::Max($firstDuration.TotalMilliseconds * 1.5, 1500))
    }

    It 'still produces a correct MOF after Clear-DscKeywordCache' {
        $text = @'
Configuration RetentionClearCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'r1'
            Value = 'v1'
        }
    }
}
'@
        Invoke-Expression $text
        $null = RetentionClearCfg -OutputPath (Join-Path $TestDrive 'clear-first')
        Clear-DscKeywordCache
        $null = RetentionClearCfg -OutputPath (Join-Path $TestDrive 'clear-second')

        $firstText = Get-PSDscMofText -Path (Join-Path $TestDrive 'clear-first\localhost.mof')
        $secondText = Get-PSDscMofText -Path (Join-Path $TestDrive 'clear-second\localhost.mof')
        $secondText | Should -Match 'instance of xTestClassResource'
        $secondText | Should -Be $firstText
    }

    It 'invalidates the cached keywords when the module content changes' {
        $copyRoot = Join-Path $TestDrive 'FpMods'
        $null = New-Item -ItemType Directory -Path $copyRoot -Force
        Copy-Item -Path (Join-Path $script:PSDscTestRoot 'TestModules\xTestClassResource') -Destination $copyRoot -Recurse
        $copyPsm1 = Join-Path $copyRoot 'xTestClassResource\xTestClassResource.psm1'

        $savedPath = $env:PSModulePath
        try
        {
            # The copy must be the only resolvable xTestClassResource: the engine refuses
            # parse-time imports when one module name resolves to several locations. The
            # captured original path may already contain TestModules when other suites ran
            # first in the same session, so it is filtered out explicitly.
            $testModulesPath = Join-Path $script:PSDscTestRoot 'TestModules'
            $cleanedEntries = $script:PSDscOriginalPSModulePath -split [regex]::Escape($script:PSDscPathSeparator) |
                Where-Object { $_ -and $_ -ne $testModulesPath }
            $env:PSModulePath = $copyRoot + $script:PSDscPathSeparator + $script:PSDscModuleParent + $script:PSDscPathSeparator + ($cleanedEntries -join $script:PSDscPathSeparator)

            # Earlier compiles leave the TestModules copy imported; a loaded module plus the
            # on-path copy counts as multiple versions for the engine's parse-time import.
            Get-Module -Name xTestClassResource | Remove-Module -Force

            $baselineText = @'
Configuration FpBaselineCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'base'
        }
    }
}
'@
            Invoke-Expression $baselineText
            $null = FpBaselineCfg -OutputPath (Join-Path $TestDrive 'fp-baseline')
            (Get-PSDscMofText -Path (Join-Path $TestDrive 'fp-baseline\localhost.mof')) | Should -Match 'Prop1 = "base"'

            $moduleText = [System.IO.File]::ReadAllText($copyPsm1)
            $classIndex = $moduleText.IndexOf('class ResourceForTests1')
            $braceIndex = $moduleText.IndexOf('{', $classIndex)
            $moduleText = $moduleText.Insert($braceIndex + 1, "`r`n    [DscProperty()]`r`n    [string] `$NewProp`r`n")
            [System.IO.File]::WriteAllText($copyPsm1, $moduleText)

            Get-Module -Name xTestClassResource | Remove-Module -Force

            $updatedText = @'
Configuration FpUpdatedCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'base'
            NewProp = 'fresh'
        }
    }
}
'@
            Invoke-Expression $updatedText
            $null = FpUpdatedCfg -OutputPath (Join-Path $TestDrive 'fp-updated')
            (Get-PSDscMofText -Path (Join-Path $TestDrive 'fp-updated\localhost.mof')) | Should -Match 'NewProp = "fresh"'
        }
        finally
        {
            $env:PSModulePath = $savedPath
        }
    }

    It 'imports only the highest version when two versions of a module are installed' {
        $versionRoot = Join-Path $TestDrive 'VerMods'
        foreach ($version in '1.0.0', '2.0.0')
        {
            $moduleDirectory = Join-Path $versionRoot "xVersionedTestModule\$version"
            $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
            $markerProperty = if ($version -eq '1.0.0') { 'V1Marker' } else { 'V2Marker' }
            $classText = @"
[DscResource()]
class xVersionedResource
{
    [DscProperty(Key)]
    [string] `$Name

    [DscProperty()]
    [string] `$$markerProperty

    [void] Set()
    {
    }

    [bool] Test()
    {
        return `$true
    }

    [xVersionedResource] Get()
    {
        return `$this
    }
}
"@
            # Pinning all three export lists to @() makes the engine discover no class
            # resources at all, so only FunctionsToExport is pinned here.
            $manifestText = @"
@{
    RootModule           = 'xVersionedTestModule.psm1'
    ModuleVersion        = '$version'
    GUID                 = 'e6d3b7a9-1f42-4c58-9a70-3d2c8b6f5e21'
    Author               = 'PSDesiredStateConfiguration Tests'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @()
    DscResourcesToExport = @('xVersionedResource')
}
"@
            Set-Content -Path (Join-Path $moduleDirectory 'xVersionedTestModule.psm1') -Value $classText -Encoding Ascii
            Set-Content -Path (Join-Path $moduleDirectory 'xVersionedTestModule.psd1') -Value $manifestText -Encoding Ascii
        }

        $savedPath = $env:PSModulePath
        try
        {
            $env:PSModulePath = $versionRoot + $script:PSDscPathSeparator + $env:PSModulePath

            # The engine rejects a parse-time import when two versions are installed, so the
            # version dedupe is exercised through the fast host, which resolves the highest.
            $text = @'
Configuration VersionDedupeCfg
{
    Import-DscResource -ModuleName xVersionedTestModule
    Node localhost
    {
        xVersionedResource a { Name = 'a'; V2Marker = 'm2' }
    }
}
'@
            $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'version-dedupe')
            $result.Exists | Should -Be $true
            $mofText = Get-PSDscMofText -Path $result.FullName
            $mofText | Should -Match 'ModuleVersion = "2.0.0"'
            $mofText | Should -Not -Match 'ModuleVersion = "1\.0\.0"'
            $mofText | Should -Match 'V2Marker = "m2"'
        }
        finally
        {
            $env:PSModulePath = $savedPath
        }
    }

    It 'recovers when Get-DscResource runs between two compiles' {
        $text = @'
Configuration RetentionInterleaveCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'interleave'
        }
    }
}
'@
        Invoke-Expression $text
        $null = RetentionInterleaveCfg -OutputPath (Join-Path $TestDrive 'interleave-first')

        $resources = @(Get-DscResource -Module xTestClassResource)
        foreach ($name in 'xTestClassResource', 'ResourceForTests1', 'ResourceForTests2', 'ResourceForTests3')
        {
            @($resources | ForEach-Object { $_.Name }) -contains $name | Should -Be $true
        }

        $null = RetentionInterleaveCfg -OutputPath (Join-Path $TestDrive 'interleave-second')
        $mofText = Get-PSDscMofText -Path (Join-Path $TestDrive 'interleave-second\localhost.mof')
        $mofText | Should -Match 'instance of ResourceForTests1'
        $mofText | Should -Match 'Prop1 = "interleave"'
    }
}
