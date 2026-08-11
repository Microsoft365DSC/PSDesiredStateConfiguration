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

    # The engine resolves PSDesiredStateConfiguration by name through PSModulePath when a
    # compiled configuration runs, so the module under test must win that resolution.
    $script:PSDscOriginalPSModulePath = $env:PSModulePath
    $moduleParent = Split-Path (Split-Path $script:PSDscModuleUnderTestManifest -Parent) -Parent
    $separator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = (Join-Path $script:PSDscTestRoot 'TestModules') + $separator + $moduleParent + $separator + $env:PSModulePath

    function Get-PSDscStripResult
    {
        param ([string]$Text)

        & (Get-Module -Name PSDesiredStateConfiguration) { Get-StrippedConfigurationText -Text $args[0] } $Text
    }

    # SourceInfo carries source line numbers, which shift when the fast host merges a
    # resource statement with its next-line property block.
    function Get-PSDscNormalizedMofLine
    {
        param ([string]$Path)

        Get-Content -Path $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^SourceInfo' } |
            Sort-Object
    }

    Import-PSDscModuleUnderTest
}

AfterAll {
    if ($script:PSDscOriginalPSModulePath)
    {
        $env:PSModulePath = $script:PSDscOriginalPSModulePath
    }
}

Describe 'Fast host contract' {
    It 'uses the PSDscFastCompileActive recursion guard global consumed by Microsoft365DSC trailers' {
        $fastHostText = [System.IO.File]::ReadAllText((Join-Path $script:PSDscRepoRoot 'src\PSDesiredStateConfiguration\FastHost.ps1'))
        $fastHostText | Should -Match '\$Global:PSDscFastCompileActive'
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

    It 'falls back with a warning for a script-based resource module and still produces the MOF' {
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
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fallback-script') -WarningVariable warnings 3>$null
        ($warnings -join ' ') | Should -Match 'Falling back to standard compilation'
        $result.Exists | Should -Be $true
        (Get-Content -Path $result.FullName -Raw) | Should -Match 'MSFT_xTestScriptResource'
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
}
