BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force

    # Test resource modules are resolved by name at parse time, so TestModules must be
    # on the path. The module under test claims the engine-qualified Configuration name
    # itself when imported, so its own location only matters for out-of-process runs.
    Add-PSDscTestModulePath
    Import-PSDscEngine

    $script:PSDscRepoRoot = Get-PSDscRepositoryRoot
    $script:PSDscModuleUnderTestManifest = Get-PSDscEngineManifest

    function Get-PSDscStripResult
    {
        param ([string]$Text)

        Invoke-PSDscInEngineScope { Get-StrippedConfigurationText -Text $args[0] } $Text
    }

    # SourceInfo carries source line numbers, which shift when the fast host merges a
    # resource statement with its next-line property block.
    function Get-PSDscNormalizedMofLine
    {
        param ([string]$Path)

        Get-PSDscComparableMofLine -Path $Path
    }
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'Fast host contract' {
    It 'uses the PSDscFastCompileActive recursion guard global consumed by Microsoft365DSC trailers' {
        $fastHostText = [System.IO.File]::ReadAllText((Join-Path $script:PSDscRepoRoot 'M365DSC.PSDesiredStateConfiguration\FastHost.ps1'))
        $fastHostText | Should -Match '\$Global:PSDscFastCompileActive'
    }

    It 'ships a compatibility module of the same version that claims the engine-resolved name' {
        $compatManifest = Join-Path $script:PSDscRepoRoot 'M365DSC.PSDesiredStateConfiguration\Compat\PSDesiredStateConfiguration\PSDesiredStateConfiguration.psd1'
        Test-Path $compatManifest | Should -Be $true
        $compat = Import-PowerShellDataFile -Path $compatManifest
        $engine = Import-PowerShellDataFile -Path $script:PSDscModuleUnderTestManifest
        $compat.ModuleVersion | Should -Be $engine.ModuleVersion
        (Get-Command 'PSDesiredStateConfiguration\Configuration').Module.Name | Should -Be 'M365DSC.PSDesiredStateConfiguration'
    }

    It 'keeps compiling through this engine after a standard compile loaded the inbox module' {
        $text = @'
Configuration ShimHandoverCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'handover'
        }
    }
}
'@
        Invoke-Expression $text
        $null = ShimHandoverCfg -OutputPath (Join-Path $TestDrive 'handover-std')

        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'handover-fast') -NoFallback
        $result.Exists | Should -Be $true
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "handover"'
        (Get-Command 'PSDesiredStateConfiguration\Configuration').Module.Name | Should -Be 'M365DSC.PSDesiredStateConfiguration'
    }
}

Describe 'Get-StrippedConfigurationText' {
    It 'strips a -ModuleName only statement and records a wildcard spec' {
        $text = @'
Configuration PlainCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ModuleSpecs).Count | Should -Be 1
        $result.ModuleSpecs[0].ModuleName | Should -Be 'xTestClassResource'
        $result.ModuleSpecs[0].ModuleVersion | Should -Be $null
        (@($result.ModuleSpecs[0].Resources) -join ',') | Should -Be '*'
        @($result.ConfigurationNames) -contains 'PlainCfg' | Should -Be $true
    }

    It 'records resource names for -Name with -ModuleName' {
        $text = @'
Configuration NamedCfg
{
    Import-DscResource -Name ResourceForTests1 -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ModuleSpecs).Count | Should -Be 1
        $result.ModuleSpecs[0].ModuleName | Should -Be 'xTestClassResource'
        (@($result.ModuleSpecs[0].Resources) -join ',') | Should -Be 'ResourceForTests1'
    }

    It 'records the module version for a quoted -ModuleVersion' {
        $text = @'
Configuration VersionCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion '1.0'
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.ModuleSpecs[0].ModuleVersion | Should -Be ([version]'1.0')
    }

    It 'supports an unquoted numeric -ModuleVersion' {
        $text = @'
Configuration BareVersionCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion 1.0
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.ModuleSpecs[0].ModuleVersion | Should -Be ([version]'1.0')
    }

    It 'records one spec per module for an array -ModuleName' {
        $text = @'
Configuration ArrayCfg
{
    Import-DscResource -ModuleName ModuleAlpha, ModuleBeta
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        @($result.ModuleSpecs).Count | Should -Be 2
        ($result.ModuleSpecs | ForEach-Object { $_.ModuleName }) -join ',' | Should -Be 'ModuleAlpha,ModuleBeta'
    }

    It 'strips multiple statements' {
        $text = @'
Configuration MultiImportCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Import-DscResource -ModuleName xTestScriptResource
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ModuleSpecs).Count | Should -Be 2
        ($result.ModuleSpecs | ForEach-Object { $_.ModuleName }) -join ',' | Should -Be 'xTestClassResource,xTestScriptResource'
    }

    It 'strips a statement inside a Node block' {
        $text = @'
Configuration NodeScopedCfg
{
    Node localhost
    {
        Import-DscResource -ModuleName xTestClassResource
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ModuleSpecs).Count | Should -Be 1
        $result.ModuleSpecs[0].ModuleName | Should -Be 'xTestClassResource'
    }

    It 'keeps Configuration occurrences in strings and comments intact' {
        $text = @'
Configuration StringCommentCfg
{
    # Preserve this Configuration comment
    $note = 'a Configuration inside a string'
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = $note
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text.Contains('# Preserve this Configuration comment') | Should -Be $true
        $result.Text.Contains("'a Configuration inside a string'") | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ConfigurationNames) -contains 'StringCommentCfg' | Should -Be $true
    }

    It 'reports variable module arguments as unsupported' {
        $text = @'
Configuration VariableCfg
{
    Import-DscResource -ModuleName $moduleName
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $false
        $result.Reason | Should -Match 'Unsupported Import-DscResource form'
    }

    It 'reports an array -ModuleName with a variable element as unsupported' {
        $text = @'
Configuration VariableArrayCfg
{
    Import-DscResource -ModuleName @('a', $someVar)
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $false
        $result.Reason | Should -Match 'Unsupported Import-DscResource form'
    }

    It 'reports an unknown parameter as unsupported' {
        $text = @'
Configuration UnknownParamCfg
{
    Import-DscResource -ModuleName xTestClassResource -Bogus 42
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $false
        $result.Reason | Should -Match 'Unsupported Import-DscResource form'
    }

    It 'reports -Name without -ModuleName as unsupported' {
        $text = @'
Configuration NameOnlyCfg
{
    Import-DscResource -Name ResourceForTests1
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $false
        $result.Reason | Should -Match 'without -ModuleName'
    }

    It 'supports the positional form' {
        $text = @'
Configuration PositionalCfg
{
    Import-DscResource ResourceForTests1 xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        $result = Get-PSDscStripResult -Text $text
        $result.Supported | Should -Be $true
        $result.Text | Should -Not -Match 'Import-DscResource'
        @($result.ModuleSpecs).Count | Should -Be 1
        $result.ModuleSpecs[0].ModuleName | Should -Be 'xTestClassResource'
        (@($result.ModuleSpecs[0].Resources) -join ',') | Should -Be 'ResourceForTests1'
    }
}

Describe 'Invoke-DscFastCompile' {
    It 'produces the same MOF content as the standard path' {
        $text = @'
Configuration FastParityCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'r1'
            Value = 'v1'
            Ensure = 'Present'
            sArray = @()
            HashTableValue = @{ k1 = 'v1' }
            EmbClassObj = EmbClass { EmbClassStr1 = 'emb1' }
        }
        ResourceForTests1 r2
        {
            Prop1 = 'p2'
            DependsOn = '[xTestClassResource]r1'
        }
    }
}
'@
        $fast = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'parity-fast')
        @($fast).Count | Should -Be 1
        $fast.Exists | Should -Be $true

        Invoke-Expression $text
        $standard = FastParityCfg -OutputPath (Join-Path $TestDrive 'parity-std')
        $standard.Exists | Should -Be $true

        $fastLines = Get-PSDscNormalizedMofLine -Path $fast.FullName
        $standardLines = Get-PSDscNormalizedMofLine -Path $standard.FullName
        @($fastLines).Count | Should -Be @($standardLines).Count
        $difference = Compare-Object -ReferenceObject @($standardLines) -DifferenceObject @($fastLines)
        @($difference).Count | Should -Be 0
    }

    It 'merges a nested CIM instance written with a next-line brace' {
        # 'PropertyName = KeywordName' parses as a single command inside a configuration
        # body, not as an assignment. The merge has to look past the property name to
        # find the keyword. Without that, the next-line brace stays a separate statement
        # and the engine reports the embedded type as an unknown command.
        $text = @'
Configuration NestedBraceCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'r1'
            Value = 'v1'
            EmbClassObj = EmbClass
            {
                EmbClassStr1 = 'emb1'
            }
            EmbClassObjArray = @(
                EmbClass
                {
                    EmbClassStr1 = 'arr1'
                }
            )
        }
    }
}
'@
        $fast = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'nested-fast') -NoFallback
        @($fast).Count | Should -Be 1
        $fast.Exists | Should -Be $true

        Invoke-Expression $text
        $standard = NestedBraceCfg -OutputPath (Join-Path $TestDrive 'nested-std')
        $standard.Exists | Should -Be $true

        $fastLines = Get-PSDscNormalizedMofLine -Path $fast.FullName
        $standardLines = Get-PSDscNormalizedMofLine -Path $standard.FullName
        $difference = Compare-Object -ReferenceObject @($standardLines) -DifferenceObject @($fastLines)
        @($difference).Count | Should -Be 0
    }

    It 'resolves each module spec once and reuses it on later compiles' {
        $text = @'
Configuration ResolveCacheCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'cached'
        }
    }
}
'@
        Invoke-PSDscInEngineScope { $script:FastHostResolvedModules = @{} }

        $null = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'resolve-1') -NoFallback
        $cached = Invoke-PSDscInEngineScope { @($script:FastHostResolvedModules.Keys) }
        $cached | Should -Contain 'xTestClassResource|'

        # A second compile must still work off the cached entry.
        $second = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'resolve-2') -NoFallback
        $second.Exists | Should -Be $true
    }

    It 'compiles property names that collide with built-in DSC keywords' {
        $text = @'
Configuration ReservedNameCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'r1'
            Value = 'v1'
            Settings = 'top-level'
            EmbClassObj = EmbClass { User = 'same-line' }
            EmbClassObjArray = @(
                EmbClass
                {
                    User = 'next-line'
                }
            )
        }
    }
}
'@
        $fast = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'reserved-fast') -NoFallback
        $fast.Exists | Should -Be $true

        Invoke-Expression $text
        $standard = ReservedNameCfg -OutputPath (Join-Path $TestDrive 'reserved-std')
        $standard.Exists | Should -Be $true

        $difference = Compare-Object -ReferenceObject @(Get-PSDscNormalizedMofLine -Path $standard.FullName) `
            -DifferenceObject @(Get-PSDscNormalizedMofLine -Path $fast.FullName)
        @($difference).Count | Should -Be 0
    }

    It 'rewrites the body of every built-in keyword name to a hashtable literal' {
        $reserved = @(
            'Archive', 'Configuration', 'Environment', 'File', 'Group', 'Log', 'Node', 'Package'
            'Registry', 'Script', 'Service', 'Settings', 'User', 'WaitForAll', 'WaitForAny'
            'WaitForSome', 'WindowsFeature', 'WindowsOptionalFeature', 'WindowsProcess'
        )

        foreach ($name in $reserved)
        {
            $text = 'Configuration C { Node localhost { ResourceForTests1 a { ' + $name + ' = "v" } } }'
            $converted = Invoke-PSDscInEngineScope {
                $merged = Merge-FastHostResourceStatements -Text $args[0] -KeywordNames @('ResourceForTests1')
                Convert-FastHostBodyToHashtable -Text $merged -KeywordNames @('ResourceForTests1')
            } $text

            { [scriptblock]::Create($converted) } | Should -Not -Throw -Because '$name must survive the rewrite'
        }
    }

    It 'compiles a self-invoking script file passed via -Path' {
        $outputDirectory = Join-Path $TestDrive 'self-out'
        $scriptPath = Join-Path $TestDrive 'SelfInvoke.ps1'
        $text = @"
Configuration SelfInvokeCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a { Prop1 = 'self' }
}
SelfInvokeCfg -OutputPath '$outputDirectory'
"@
        Set-Content -Path $scriptPath -Value $text -Encoding Ascii
        $result = Invoke-DscFastCompile -Path $scriptPath
        @($result).Count | Should -Be 1
        $result | Should -BeOfType ([System.IO.FileInfo])
        $result.Name | Should -Be 'localhost.mof'
        $result.DirectoryName | Should -Be $outputDirectory
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'instance of ResourceForTests1'
    }

    It 'compiles a schema based resource module through the fast path' {
        $text = @'
Configuration FallbackScriptCfg
{
    Import-DscResource -ModuleName xTestScriptResource
    Node localhost
    {
        xTestScriptResource one
        {
            Name = 'first'
            Ensure = 'Present'
            Items = @('a', 'b')
        }
    }
}
'@
        $warnings = $null
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fallback-script') -NoFallback -WarningVariable warnings 3>$null
        $warnings | Should -BeNullOrEmpty
        $result.Exists | Should -Be $true
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'MSFT_xTestScriptResource'
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Items = \{'
    }

    It 'falls back with a warning for a composite resource module and still produces the MOF' {
        $text = @'
Configuration FallbackCompositeCfg
{
    Import-DscResource -ModuleName xTestCompositeResource
    Node localhost
    {
        xTestComposite c1
        {
            Marker = 'x'
        }
    }
}
'@
        $warnings = $null
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fallback-composite') -WarningVariable warnings 3>$null
        ($warnings -join ' ') | Should -Match 'Falling back to standard compilation'
        $result.Exists | Should -Be $true
        $content = Get-Content -Path $result.FullName -Raw
        $content | Should -Match 'instance of ResourceForTests1'
        $content | Should -Match 'Prop1 = "x"'
    }

    It 'throws with -NoFallback on an unsupported Import-DscResource form' {
        $text = @'
Configuration NoFallbackCfg
{
    Import-DscResource -ModuleName $moduleName
    ResourceForTests1 a
    {
        Prop1 = 'x'
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -NoFallback -OutputPath (Join-Path $TestDrive 'no-fallback') } | Should -Throw
    }

    It 'compiles both nodes of a multi-node configuration through the fast path' {
        $text = @'
Configuration MultiNodeFastCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node $AllNodes.Where({ $true }).NodeName
    {
        ResourceForTests1 marker
        {
            Prop1 = $Node.NodeName
        }
        ResourceForTests2 second
        {
            Prop1 = 'fixed'
        }
    }
}
'@
        $configurationData = @{
            AllNodes = @(
                @{ NodeName = 'NodeA' }
                @{ NodeName = 'NodeB' }
            )
        }
        $result = Invoke-DscFastCompile -ScriptText $text -ConfigurationData $configurationData -OutputPath (Join-Path $TestDrive 'multi-node')
        @($result).Count | Should -Be 2
        (($result | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should -Be 'NodeA.mof,NodeB.mof'
        foreach ($mof in $result)
        {
            $nodeName = [System.IO.Path]::GetFileNameWithoutExtension($mof.Name)
            $content = Get-Content -Path $mof.FullName -Raw
            $content | Should -Match ('Prop1 = "' + $nodeName + '"')
            $content | Should -Match 'Prop1 = "fixed"'
        }
    }

    It 'honours a pinned module version' {
        $text = @'
Configuration PinnedVersionCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion '1.0'
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'pinned'
        }
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'pinned-version') -NoFallback

        $result.Exists | Should -Be $true
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "pinned"'
    }

    It 'falls back when the pinned module version is not installed' {
        $text = @'
Configuration MissingVersionCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion '99.0'
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'missing-version') -NoFallback } |
            Should -Throw -ExpectedMessage "*version 99.0 was not found*"
    }

    It 'falls back when the module is not installed at all' {
        $text = @'
Configuration MissingModuleCfg
{
    Import-DscResource -ModuleName xTestModuleThatDoesNotExist
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'missing-module') -NoFallback } |
            Should -Throw -ExpectedMessage "*'xTestModuleThatDoesNotExist' was not found*"
    }

    It 'compiles the requested configuration when the script defines several' {
        $text = @'
Configuration FirstOfTwoCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'first'
    }
}

Configuration SecondOfTwoCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'second'
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -ConfigurationName SecondOfTwoCfg `
            -OutputPath (Join-Path $TestDrive 'second-of-two') -NoFallback

        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "second"'
    }

    It 'requires a configuration name when the script defines several' {
        $text = @'
Configuration AmbiguousOneCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'one'
    }
}

Configuration AmbiguousTwoCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = 'two'
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'ambiguous-name') -NoFallback } |
            Should -Throw -ExpectedMessage '*specify -ConfigurationName*'
    }

    It 'passes configuration parameters through -Parameters' {
        $text = @'
Configuration ParameterizedCfg
{
    param
    (
        [string]
        $Marker
    )

    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 a
    {
        Prop1 = $Marker
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -Parameters @{ Marker = 'from-parameter' } `
            -OutputPath (Join-Path $TestDrive 'parameterized') -NoFallback

        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "from-parameter"'
    }

    It 'keeps the property values of two configurations whose property blocks share their offsets apart' {
        $first = @'
Configuration OffsetTwinOneCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'first'
        }
    }
}
'@
        $second = @'
Configuration OffsetTwinTwoCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'other'
        }
    }
}
'@
        $firstResult = Invoke-DscFastCompile -ScriptText $first -OutputPath (Join-Path $TestDrive 'offset-twin-one') -NoFallback
        $secondResult = Invoke-DscFastCompile -ScriptText $second -OutputPath (Join-Path $TestDrive 'offset-twin-two') -NoFallback

        (Get-Content -Path $firstResult.FullName -Raw) | Should -Match 'Prop1 = "first"'
        (Get-Content -Path $secondResult.FullName -Raw) | Should -Match 'Prop1 = "other"'
        (Get-Content -Path $secondResult.FullName -Raw) | Should -Not -Match 'Prop1 = "first"'
    }

    It 'joins a resource statement with a property block on the next line' {
        $text = @'
Configuration NextLineBraceCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'next-line'
        }
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'next-line-brace') -NoFallback

        (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "next-line"'
    }

    It 'generates a schema cache for a module that has none yet' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.6' `
            -Destination (Join-Path $TestDrive 'fresh-cache-module')

        $originalModulePath = $env:PSModulePath
        $env:PSModulePath = $isolated.Root + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Reset-PSDscFastHostState

        $text = @'
Configuration FreshCacheCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion '1.6'
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'fresh'
        }
    }
}
'@
        try
        {
            $isolated.UserCachePath | Should -Not -Exist

            $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fresh-cache-out') -NoFallback

            $isolated.UserCachePath | Should -Exist
            (Get-Content -Path $result.FullName -Raw) | Should -Match 'Prop1 = "fresh"'
        }
        finally
        {
            Remove-Item -Path $isolated.UserCachePath -Force -ErrorAction Ignore
            $env:PSModulePath = $originalModulePath
            Reset-PSDscFastHostState
        }
    }
}

Describe 'Fast host resource adapter' {
    It 'reports a resource keyword that the schema cache does not know' {
        $text = @'
Configuration UnknownKeywordCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
        xTestResourceThatIsNotCached b
        {
            Prop1 = 'y'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'unknown-keyword') -NoFallback
        }

        $diagnostics | Should -Match 'xTestResourceThatIsNotCached'
    }

    It 'reports a resource statement without an instance name' {
        $text = @'
Configuration NamelessResourceCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1
        {
            Prop1 = 'x'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'nameless-resource') -NoFallback
        }

        $diagnostics | Should -Match 'instance name'
    }

    It 'reports a value outside the value map of a property' {
        $text = @'
Configuration FastBadValueMapCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource a
        {
            Name = 'n'
            Value = 'v'
            Ensure = 'Perhaps'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-bad-valuemap') -NoFallback
        }

        $diagnostics | Should -Match 'Perhaps'
    }

    It 'reports two resources sharing one resource id' {
        $text = @'
Configuration FastDuplicateIdCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 same
        {
            Prop1 = 'first'
        }
        ResourceForTests1 same
        {
            Prop1 = 'second'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-duplicate-id') -NoFallback
        }

        $diagnostics | Should -Match "A duplicate resource identifier '\[ResourceForTests1\]same' was found"
    }

    It 'reports a malformed DependsOn reference' {
        $text = @'
Configuration FastBadDependsOnCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            DependsOn = 'ResourceForTests2b'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-bad-dependson') -NoFallback
        }

        $diagnostics | Should -Match "resource reference 'ResourceForTests2b'"
        Join-Path $TestDrive 'fast-bad-dependson\localhost.mof' | Should -Not -Exist
    }

    It 'reports two resources with identical keys but different non-key values' {
        $text = @'
Configuration FastConflictingCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource first
        {
            Name = 'shared-key'
            Value = 'one'
        }
        xTestClassResource second
        {
            Name = 'shared-key'
            Value = 'two'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-conflicting') -NoFallback
        }

        $diagnostics | Should -Match 'A conflict was detected between resources'
    }

    It 'reports a missing mandatory property at compile time' {
        $text = @'
Configuration FastMissingMandatoryCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource a
        {
            Name = 'only-the-key'
        }
    }
}
'@
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-missing-mandatory') -NoFallback
        }

        $diagnostics | Should -Match 'Value'
    }
}

Describe 'Fast host module resolution and rewrite' {
    BeforeAll {
        Reset-PSDscFastHostState
    }

    AfterAll {
        Reset-PSDscFastHostState
    }

    It 'resolves an installed module from the manifest alone' {
        $module = Invoke-PSDscInEngineScope { Resolve-FastHostModule -ModuleName 'xTestClassResource' }

        $module.Name | Should -Be 'xTestClassResource'
        $module.Version | Should -Be ([version]'1.0')
        $module.Path | Should -Be (Join-Path $module.ModuleBase 'xTestClassResource.psd1')
        $module.Path | Should -Exist
    }

    It 'returns nothing for a version that is not installed' {
        Invoke-PSDscInEngineScope { Resolve-FastHostModule -ModuleName 'xTestClassResource' -ModuleVersion '99.0' } | Should -BeNullOrEmpty
    }

    It 'prefers the highest version folder and honors a requested one' {
        $root = Join-Path $TestDrive 'resolve-root'
        foreach ($version in '1.0', '2.5')
        {
            $folder = Join-Path $root "xVersionedProbe\$version"
            $null = New-Item -ItemType Directory -Path $folder -Force
            New-ModuleManifest -Path (Join-Path $folder 'xVersionedProbe.psd1') -ModuleVersion $version
        }
        $originalPath = $env:PSModulePath
        $env:PSModulePath = $root + [System.IO.Path]::PathSeparator + $env:PSModulePath
        try
        {
            (Invoke-PSDscInEngineScope { Resolve-FastHostModule -ModuleName 'xVersionedProbe' }).Version | Should -Be ([version]'2.5')
            (Invoke-PSDscInEngineScope { Resolve-FastHostModule -ModuleName 'xVersionedProbe' -ModuleVersion '1.0' }).Version | Should -Be ([version]'1.0')
        }
        finally
        {
            $env:PSModulePath = $originalPath
        }
    }

    It 'rewrites imports, next-line braces and bodies in one pass like the sequential passes' {
        $text = @'
Configuration OnePassCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
        xTestClassResource b { Name = 'n'; Value = 'v'; Ensure = 'Present'; sArray = @('s') }
    }
}
'@
        $input = @{ Text = $text; Names = @('ResourceForTests1', 'xTestClassResource') }
        $onePass = Invoke-PSDscInEngineScope {
            $strip = Get-StrippedConfigurationText -Text $args[0].Text
            ConvertTo-FastHostCompileText -Text $args[0].Text -Ast $strip.Ast -ImportStatement $strip.ImportStatements -KeywordNames $args[0].Names -Merge -Convert
        } $input
        $sequential = Invoke-PSDscInEngineScope {
            $strip = Get-StrippedConfigurationText -Text $args[0].Text
            $merged = Merge-FastHostResourceStatements -Text $strip.Text -KeywordNames $args[0].Names
            Convert-FastHostBodyToHashtable -Text $merged -KeywordNames $args[0].Names
        } $input

        $onePass | Should -BeExactly $sequential
        $onePass | Should -Not -Match 'Import-DscResource'
        $onePass | Should -Match 'ResourceForTests1 a @\{'
        $onePass | Should -Match 'xTestClassResource b @\{'
    }

    It 'deserializes only the keywords a compile uses' {
        Reset-PSDscFastHostState
        $text = @'
Configuration LazyCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a { Prop1 = 'lazy' }
    }
}
'@
        $null = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'lazy-out') -NoFallback

        $materialized = @(Invoke-PSDscInEngineScope { @($script:FastHostKeywords.Keys) })
        $materialized | Should -Contain 'ResourceForTests1'
        $materialized | Should -Not -Contain 'xTestClassResource'
        (Invoke-PSDscInEngineScope { (Get-FastHostKeywordName).Count }) | Should -Be 5
    }

    It 'reports stage timings for the last compile' {
        $timing = Get-DscFastCompileTiming

        @($timing.Keys) | Should -Be @('parse', 'resolve', 'cache', 'rewrite', 'compile', 'total')
        $timing['total'] | Should -BeGreaterOrEqual $timing['compile']
    }

    It 'regenerates the cache with -Force' {
        $module = Get-Module -ListAvailable -Name xTestClassResource | Select-Object -First 1
        $userPath = Invoke-PSDscInEngineScope {
            Get-DscSchemaCacheUserPath -ModuleName $args[0].Name -ModuleVersion $args[0].Version -Fingerprint (Get-DscModuleFingerprint -Module $args[0])
        } $module
        Remove-Item -Path $userPath -Force -ErrorAction Ignore
        $text = @'
Configuration ForceCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a { Prop1 = 'force' }
    }
}
'@
        try
        {
            $null = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'force-out') -NoFallback -Force

            $userPath | Should -Exist
        }
        finally
        {
            Remove-Item -Path $userPath -Force -ErrorAction Ignore
        }
    }
}
