BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'Meta configuration compilation' {
    BeforeAll {
        # A meta configuration exercises Write-MetaConfigFile and Update-LocalConfigManager: the
        # embedded manager lists and the meta OMI_ConfigurationDocument. The standard suites never
        # reach that code.
        $text = @'
[DSCLocalConfigurationManager()]
configuration MetaProbeCfg
{
    Node localhost
    {
        Settings
        {
            RefreshMode = 'Pull'
            ConfigurationMode = 'ApplyAndAutoCorrect'
            RebootNodeIfNeeded = $true
        }

        ConfigurationRepositoryWeb PullServer
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
            ConfigurationNames = @('Config1')
        }

        ResourceRepositoryWeb ResourceServer
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
        }

        ReportServerWeb Reporting
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
        }

        PartialConfiguration Partial1
        {
            Description = 'partial'
            ConfigurationSource = @('[ConfigurationRepositoryWeb]PullServer')
            ResourceModuleSource = @('[ResourceRepositoryWeb]ResourceServer')
            RefreshMode = 'Pull'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'meta'
        $null = Invoke-PSDscConfigurationText -Text $text -Name MetaProbeCfg -OutputPath $outputPath
        $script:MetaMofPath = Join-Path $outputPath 'localhost.meta.mof'
        $script:MetaMof = if (Test-Path -LiteralPath $script:MetaMofPath) { Get-Content -LiteralPath $script:MetaMofPath -Raw } else { '' }
    }

    It 'writes a meta MOF' {
        Test-Path -LiteralPath $script:MetaMofPath | Should -Be $true
    }

    It 'keeps the meta configuration settings instance' {
        $script:MetaMof | Should -Match 'instance of MSFT_DSCMetaConfiguration'
        $script:MetaMof | Should -Match 'RefreshMode = "Pull"'
        $script:MetaMof | Should -Match 'ConfigurationMode = "ApplyAndAutoCorrect"'
    }

    It 'embeds each manager kind that the configuration declares' {
        $script:MetaMof | Should -Match 'ConfigurationDownloadManagers = \{'
        $script:MetaMof | Should -Match 'ResourceModuleManagers = \{'
        $script:MetaMof | Should -Match 'ReportManagers = \{'
        $script:MetaMof | Should -Match 'PartialConfigurations = \{'
    }

    It 'closes the document with an OMI_ConfigurationDocument instance' {
        $script:MetaMof | Should -Match 'instance of OMI_ConfigurationDocument'
        $script:MetaMof | Should -Match 'MinimumCompatibleVersion = "[0-9.]+"'
        $script:MetaMof | Should -Match 'CompatibleVersionAdditionalProperties='
    }

    It 'carries no volatile generation metadata' {
        $script:MetaMof | Should -Not -Match 'GenerationDate'
        $script:MetaMof | Should -Not -Match 'GenerationHost'
    }
}

Describe 'Meta configuration without managers' {
    It 'omits manager kinds the configuration does not declare' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MinimalMetaCfg
{
    Node localhost
    {
        Settings
        {
            RefreshMode = 'Push'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'minimal-meta'
        $null = Invoke-PSDscConfigurationText -Text $text -Name MinimalMetaCfg -OutputPath $outputPath
        $mof = Get-Content -LiteralPath (Join-Path $outputPath 'localhost.meta.mof') -Raw

        $mof | Should -Match 'RefreshMode = "Push"'
        $mof | Should -Not -Match 'ResourceModuleManagers = \{'
        $mof | Should -Not -Match 'ReportManagers = \{'
        $mof | Should -Not -Match 'ConfigurationDownloadManagers = \{'
        $mof | Should -Not -Match 'PartialConfigurations = \{'
    }

    It 'adds an empty settings instance when the configuration declares none' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration NoSettingsMetaCfg
{
    Node localhost
    {
        ConfigurationRepositoryWeb PullServer
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
            ConfigurationNames = @('Config1')
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'no-settings-meta'
        $null = Invoke-PSDscConfigurationText -Text $text -Name NoSettingsMetaCfg -OutputPath $outputPath
        $mof = Get-Content -LiteralPath (Join-Path $outputPath 'localhost.meta.mof') -Raw

        $mof | Should -Match 'instance of MSFT_DSCMetaConfiguration as \$MSFT_DSCMetaConfiguration1ref'
        $mof | Should -Match 'ConfigurationDownloadManagers = \{'
    }

    It 'reports more than one settings instance for a node' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration TwoSettingsMetaCfg
{
    Node localhost
    {
        Settings
        {
            RefreshMode = 'Push'
        }
        Settings
        {
            RefreshMode = 'Pull'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name TwoSettingsMetaCfg -OutputPath (Join-Path $TestDrive 'two-settings-meta')

        $diagnostics | Should -Match 'more than one definitions for LocalConfigurationManager'
    }

    It 'rejects more than one DebugMode value' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration DebugModeMetaCfg
{
    Node localhost
    {
        Settings
        {
            DebugMode = @('ForceModuleImport', 'All')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name DebugModeMetaCfg -OutputPath (Join-Path $TestDrive 'debugmode-meta')

        $diagnostics | Should -Match 'DebugMode'
    }
}

Describe 'Partial configuration validation' {
    It 'requires a configuration source for a pull mode partial configuration' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration PullWithoutSourceCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Pull'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name PullWithoutSourceCfg -OutputPath (Join-Path $TestDrive 'pull-no-source')

        $diagnostics | Should -Match 'ConfigurationSource'
    }

    It 'rejects a disabled refresh mode for a partial configuration' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration DisabledRefreshCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Disabled'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name DisabledRefreshCfg -OutputPath (Join-Path $TestDrive 'disabled-refresh')

        $diagnostics | Should -Match 'Disabled'
    }

    It 'reports a configuration source that is not defined' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MissingManagerCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            ConfigurationSource = @('[ConfigurationRepositoryWeb]Absent')
            RefreshMode = 'Pull'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name MissingManagerCfg -OutputPath (Join-Path $TestDrive 'missing-manager')

        $diagnostics | Should -Match 'Download Manager .* does not exist'
    }

    It 'reports a resource module source that is not defined' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MissingResourceSourceCfg
{
    Node localhost
    {
        ConfigurationRepositoryWeb PullServer
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
            ConfigurationNames = @('Config1')
        }
        PartialConfiguration Partial1
        {
            ConfigurationSource = @('[ConfigurationRepositoryWeb]PullServer')
            ResourceModuleSource = @('[ResourceRepositoryWeb]Absent')
            RefreshMode = 'Pull'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name MissingResourceSourceCfg -OutputPath (Join-Path $TestDrive 'missing-resource-source')

        $diagnostics | Should -Match 'Resource Repository .* does not exist'
    }
}

Describe 'Exclusive resource validation' {
    It 'accepts exclusive resources that do not overlap' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration DistinctExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests2')
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'distinct-exclusive'
        $null = Invoke-PSDscConfigurationText -Text $text -Name DistinctExclusiveCfg -OutputPath $outputPath

        Join-Path $outputPath 'localhost.meta.mof' | Should -Exist
    }

    It 'reports a module wildcard that overlaps a named resource' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration WildcardExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\*')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name WildcardExclusiveCfg -OutputPath (Join-Path $TestDrive 'wildcard-exclusive')

        $diagnostics | Should -Match 'coflicting exclusive resource declarations'
    }

    It 'reports the same module qualified resource in two partial configurations' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration RepeatedExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name RepeatedExclusiveCfg -OutputPath (Join-Path $TestDrive 'repeated-exclusive')

        $diagnostics | Should -Match 'coflicting exclusive resource declarations'
    }

    It 'reports the same bare resource name in two partial configurations' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration BareExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('ResourceForTests1')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('ResourceForTests1')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name BareExclusiveCfg -OutputPath (Join-Path $TestDrive 'bare-exclusive')

        $diagnostics | Should -Match 'coflicting exclusive resource declarations'
    }

    It 'reports a bare resource name that a module qualified declaration already claims' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MixedExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('ResourceForTests1')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name MixedExclusiveCfg -OutputPath (Join-Path $TestDrive 'mixed-exclusive')

        $diagnostics | Should -Match 'coflicting exclusive resource declarations'
    }

    It 'reports a malformed exclusive resource reference' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MalformedExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\Resource\Deep')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name MalformedExclusiveCfg -OutputPath (Join-Path $TestDrive 'malformed-exclusive')

        $diagnostics | Should -Match 'exclusive resource name should be in the format'
    }
}

Describe 'Version 1 local configuration manager' {
    BeforeAll {
        $text = @'
configuration V1LcmCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        $script:V1OutputPath = Join-Path $TestDrive 'v1-lcm'
        $null = Invoke-PSDscConfigurationText -Text $text -Name V1LcmCfg -OutputPath $script:V1OutputPath
    }

    It 'writes both the node MOF and the meta MOF' {
        Join-Path $script:V1OutputPath 'localhost.mof' | Should -Exist
        Join-Path $script:V1OutputPath 'localhost.meta.mof' | Should -Exist
    }

    It 'keeps the resources out of the meta MOF' {
        $metaMof = Get-Content -LiteralPath (Join-Path $script:V1OutputPath 'localhost.meta.mof') -Raw
        $nodeMof = Get-Content -LiteralPath (Join-Path $script:V1OutputPath 'localhost.mof') -Raw

        $metaMof | Should -Match 'ConfigurationMode = "ApplyOnly"'
        $metaMof | Should -Not -Match 'instance of ResourceForTests1'
        $nodeMof | Should -Match 'instance of ResourceForTests1'
        $nodeMof | Should -Not -Match 'MSFT_DSCMetaConfiguration'
    }

    It 'rejects a version 2 only property' {
        $text = @'
configuration V1LcmInvalidCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            StatusRetentionTimeInDays = 5
        }

        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name V1LcmInvalidCfg -OutputPath (Join-Path $TestDrive 'v1-lcm-invalid')

        $diagnostics | Should -Match 'StatusRetentionTimeInDays'
    }
}
