BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'ConfigurationData validation' {
    BeforeAll {
        $script:Text = @'
configuration ConfigurationDataCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
    }

    It 'rejects configuration data without AllNodes' {
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $script:Text -Name ConfigurationDataCfg `
            -OutputPath (Join-Path $TestDrive 'no-allnodes') -ConfigurationData @{ Nodes = @() }

        $diagnostics | Should -Match 'need to have property AllNodes'
    }

    It 'rejects an AllNodes value that is not a collection' {
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $script:Text -Name ConfigurationDataCfg `
            -OutputPath (Join-Path $TestDrive 'allnodes-scalar') -ConfigurationData @{ AllNodes = 'localhost' }

        $diagnostics | Should -Match 'AllNodes needs to be a collection'
    }

    It 'rejects an AllNodes entry that is not a hashtable' {
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $script:Text -Name ConfigurationDataCfg `
            -OutputPath (Join-Path $TestDrive 'allnodes-string') -ConfigurationData @{ AllNodes = @('localhost') }

        $diagnostics | Should -Match "all elements of AllNodes need to be hashtable"
    }

    It 'rejects an AllNodes entry without a NodeName' {
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $script:Text -Name ConfigurationDataCfg `
            -OutputPath (Join-Path $TestDrive 'allnodes-nameless') -ConfigurationData @{ AllNodes = @(@{ Role = 'Web' }) }

        $diagnostics | Should -Match "all elements of AllNodes need to be hashtable"
    }

    It 'rejects duplicated node names' {
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $script:Text -Name ConfigurationDataCfg `
            -OutputPath (Join-Path $TestDrive 'allnodes-duplicate') `
            -ConfigurationData @{ AllNodes = @(@{ NodeName = 'localhost' }, @{ NodeName = 'LOCALHOST' }) }

        $diagnostics | Should -Match 'duplicated NodeNames'
    }

    It 'copies the wildcard node settings into every named node' {
        $text = @'
configuration WildcardNodeCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node $AllNodes.NodeName
    {
        ResourceForTests1 a
        {
            Prop1 = $Node.SharedValue
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'wildcard-node'
        $result = Invoke-PSDscConfigurationText -Text $text -Name WildcardNodeCfg -OutputPath $outputPath -ConfigurationData @{
            AllNodes = @(
                @{ NodeName = '*'; SharedValue = 'shared' }
                @{ NodeName = 'NodeA' }
                @{ NodeName = 'NodeB'; SharedValue = 'own' }
            )
        }

        (($result | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should -Be 'NodeA.mof,NodeB.mof'
        Get-Content -Raw -Path (Join-Path $outputPath 'NodeA.mof') | Should -Match 'Prop1 = "shared"'
        Get-Content -Raw -Path (Join-Path $outputPath 'NodeB.mof') | Should -Match 'Prop1 = "own"'
    }

    It 'produces no MOF when the node name list is empty' {
        $text = @'
configuration EmptyNodeSetCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node $AllNodes.Where({ $_.Role -eq 'Missing' }).NodeName
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'empty-node-set'
        $result = Invoke-PSDscConfigurationText -Text $text -Name EmptyNodeSetCfg -OutputPath $outputPath -ConfigurationData @{
            AllNodes = @(@{ NodeName = 'NodeA'; Role = 'Web' })
        }

        $result | Should -BeNullOrEmpty
        @(Get-ChildItem -Path $outputPath -Filter '*.mof' -ErrorAction Ignore).Count | Should -Be 0
    }
}

Describe 'Resource statement validation' {
    It 'rejects a missing mandatory property while parsing' {
        $text = @'
configuration MissingMandatoryCfg
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
        { Invoke-Expression -Command $text } |
            Should -Throw -ExpectedMessage "*requires that a value of type 'String' be provided for property 'Value'*"
    }

    It 'reports two resources sharing one resource id' {
        $text = @'
configuration DuplicateIdCfg
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
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name DuplicateIdCfg -OutputPath (Join-Path $TestDrive 'duplicate-id')

        $diagnostics | Should -Match "A duplicate resource identifier '\[ResourceForTests1\]same' was found"
    }

    It 'reports a malformed DependsOn reference' {
        $text = @'
configuration BadDependsOnCfg
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
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name BadDependsOnCfg -OutputPath (Join-Path $TestDrive 'bad-dependson')

        $diagnostics | Should -Match "resource reference 'ResourceForTests2b'"
        Join-Path $TestDrive 'bad-dependson\localhost.mof' | Should -Not -Exist
    }

    It 'reports a DependsOn reference to a resource that is not defined' {
        $text = @'
configuration MissingDependsOnCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            DependsOn = '[ResourceForTests2]absent'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name MissingDependsOnCfg -OutputPath (Join-Path $TestDrive 'absent-dependson')

        $diagnostics | Should -Match 'does not exist'
    }

    It 'reports a resource that depends on itself' {
        $text = @'
configuration SelfDependsOnCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            DependsOn = '[ResourceForTests1]a'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name SelfDependsOnCfg -OutputPath (Join-Path $TestDrive 'self-dependson')

        $diagnostics | Should -Match 'Circular DependsOn'
    }

    It 'reports a DependsOn cycle across two resources' {
        $text = @'
configuration CircularDependsOnCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            DependsOn = '[ResourceForTests2]b'
        }
        ResourceForTests2 b
        {
            Prop1 = 'y'
            DependsOn = '[ResourceForTests1]a'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name CircularDependsOnCfg -OutputPath (Join-Path $TestDrive 'circular-dependson')

        $diagnostics | Should -Match 'Circular DependsOn'
    }

    It 'reports two resources with identical keys but different non-key values' {
        $text = @'
configuration ConflictingCfg
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
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name ConflictingCfg -OutputPath (Join-Path $TestDrive 'conflicting')

        $diagnostics | Should -Match 'A conflict was detected between resources'
        $diagnostics | Should -Match 'Value'
    }

    It 'accepts two resources with identical keys and identical non-key values' {
        $text = @'
configuration NonConflictingCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource first
        {
            Name = 'shared-key'
            Value = 'same'
        }
        xTestClassResource second
        {
            Name = 'shared-key'
            Value = 'same'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'non-conflicting'
        $result = Invoke-PSDscConfigurationText -Text $text -Name NonConflictingCfg -OutputPath $outputPath

        $result.Exists | Should -Be $true
        $content = Get-Content -Raw -Path $result.FullName
        $content | Should -Match '\[xTestClassResource\]first'
        $content | Should -Match '\[xTestClassResource\]second'
    }

    It 'accepts two resources with different keys and different values' {
        $text = @'
configuration DistinctKeysCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource first
        {
            Name = 'key-one'
            Value = 'one'
        }
        xTestClassResource second
        {
            Name = 'key-two'
            Value = 'two'
        }
    }
}
'@
        $result = Invoke-PSDscConfigurationText -Text $text -Name DistinctKeysCfg -OutputPath (Join-Path $TestDrive 'distinct-keys')

        $result.Exists | Should -Be $true
    }

    It 'reports a value that cannot be converted to the declared property type' {
        $text = @'
configuration BadTypeCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource a
        {
            Name = 'n'
            Value = 'v'
            bValue = 'not-a-boolean'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name BadTypeCfg -OutputPath (Join-Path $TestDrive 'bad-type')

        $diagnostics | Should -Match 'Boolean'
    }

}

Describe 'Node statement validation' {
    It 'reports a localhost node next to resources defined outside any node' {
        $text = @'
configuration LocalhostMixCfg
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 outside
    {
        Prop1 = 'outside'
    }
    Node localhost
    {
        ResourceForTests2 inside
        {
            Prop1 = 'inside'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name LocalhostMixCfg -OutputPath (Join-Path $TestDrive 'localhost-mix')

        $diagnostics | Should -Match "is not allowed since the configuration already contains"
    }

    It 'reports a node definition nested inside another node' {
        $text = @'
configuration NestedNodeCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node NodeA
    {
        Node NodeB
        {
            ResourceForTests1 a
            {
                Prop1 = 'x'
            }
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name NestedNodeCfg -OutputPath (Join-Path $TestDrive 'nested-node')

        $diagnostics | Should -Match 'cannot be nested'
    }
}
