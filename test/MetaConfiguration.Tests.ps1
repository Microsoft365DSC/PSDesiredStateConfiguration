BeforeAll {
    $script:PSDscTestRoot = $PSScriptRoot
    $script:PSDscRepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PSDscModuleUnderTestManifest = Join-Path $script:PSDscRepoRoot 'M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1'

    $script:PSDscOriginalPSModulePath = $env:PSModulePath
    $separator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = (Join-Path $script:PSDscTestRoot 'TestModules') + $separator + $env:PSModulePath

    Get-Module -Name M365DSC.PSDesiredStateConfiguration | Remove-Module -Force
    Import-Module $script:PSDscModuleUnderTestManifest -Force

    # A meta configuration exercises Write-MetaConfigFile and Update-LocalConfigManager: the
    # embedded manager lists and the meta OMI_ConfigurationDocument. The standard suites never
    # reach that code.
    $script:PSDscMetaConfigurationText = @'
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

        ReportServerWeb Reporting
        {
            ServerURL = 'https://pullserver:8080/PSDSCPullServer.svc'
            RegistrationKey = '00000000-0000-0000-0000-000000000000'
        }

        PartialConfiguration Partial1
        {
            Description = 'partial'
            ConfigurationSource = @('[ConfigurationRepositoryWeb]PullServer')
            RefreshMode = 'Pull'
        }
    }
}
'@

    Invoke-Expression $script:PSDscMetaConfigurationText
    $script:PSDscMetaOutput = Join-Path $TestDrive 'meta'
    $null = MetaProbeCfg -OutputPath $script:PSDscMetaOutput
    $script:PSDscMetaMofPath = Join-Path $script:PSDscMetaOutput 'localhost.meta.mof'
    $script:PSDscMetaMof = if (Test-Path -LiteralPath $script:PSDscMetaMofPath) { Get-Content -LiteralPath $script:PSDscMetaMofPath -Raw } else { '' }
}

AfterAll {
    if ($script:PSDscOriginalPSModulePath)
    {
        $env:PSModulePath = $script:PSDscOriginalPSModulePath
    }
}

Describe 'Meta configuration compilation' {
    It 'writes a meta MOF' {
        Test-Path -LiteralPath $script:PSDscMetaMofPath | Should -Be $true
    }

    It 'keeps the meta configuration settings instance' {
        $script:PSDscMetaMof | Should -Match 'instance of MSFT_DSCMetaConfiguration'
        $script:PSDscMetaMof | Should -Match "RefreshMode = ""Pull"""
        $script:PSDscMetaMof | Should -Match "ConfigurationMode = ""ApplyAndAutoCorrect"""
    }

    It 'embeds each manager kind that the configuration declares' {
        $script:PSDscMetaMof | Should -Match 'ConfigurationDownloadManagers = \{'
        $script:PSDscMetaMof | Should -Match 'ReportManagers = \{'
        $script:PSDscMetaMof | Should -Match 'PartialConfigurations = \{'
    }

    It 'omits manager kinds the configuration does not declare' {
        $script:PSDscMetaMof | Should -Not -Match 'ResourceModuleManagers = \{'
    }

    It 'closes the document with an OMI_ConfigurationDocument instance' {
        $script:PSDscMetaMof | Should -Match 'instance of OMI_ConfigurationDocument'
        $script:PSDscMetaMof | Should -Match 'MinimumCompatibleVersion = "[0-9.]+"'
        $script:PSDscMetaMof | Should -Match 'CompatibleVersionAdditionalProperties='
    }

    It 'carries no volatile generation metadata' {
        $script:PSDscMetaMof | Should -Not -Match 'GenerationDate'
        $script:PSDscMetaMof | Should -Not -Match 'GenerationHost'
    }
}
