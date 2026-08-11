BeforeAll {
    $script:PSDscTestRoot = $PSScriptRoot
    $script:PSDscRepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PSDscModuleUnderTestManifest = @(
        (Join-Path $script:PSDscRepoRoot 'out\M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1')
        (Join-Path $script:PSDscRepoRoot 'src\M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    function Import-PSDscModuleUnderTest
    {
        Get-Module -Name M365DSC.PSDesiredStateConfiguration | Remove-Module -Force
        Import-Module $script:PSDscModuleUnderTestManifest -Force
    }

    $script:PSDscOriginalPSModulePath = $env:PSModulePath
    $moduleParent = Split-Path (Split-Path $script:PSDscModuleUnderTestManifest -Parent) -Parent
    $separator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = (Join-Path $script:PSDscTestRoot 'TestModules') + $separator + $moduleParent + $separator + $env:PSModulePath

    function ConvertFrom-PSDscKeywordSchemaObject
    {
        param ($SchemaObject)

        & (Get-Module -Name M365DSC.PSDesiredStateConfiguration) { ConvertFrom-DscKeywordSchemaObject -SchemaObject $args[0] } $SchemaObject
    }

    Import-PSDscModuleUnderTest
}

AfterAll {
    if ($script:PSDscOriginalPSModulePath)
    {
        $env:PSModulePath = $script:PSDscOriginalPSModulePath
    }
}

Describe 'Export-DscSchemaCache' {
    BeforeAll {
        $script:CachePath = Join-Path $TestDrive 'xTestClassResource-cache.json'
        $script:Summary = Export-DscSchemaCache -ModuleName xTestClassResource -OutputPath $script:CachePath
        $script:Cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:CachePath))
    }

    It 'returns a summary with 4 resources and 5 keywords' {
        $script:Summary.ModuleName | Should -Be 'xTestClassResource'
        $script:Summary.ModuleVersion | Should -Be ([version]'1.0')
        $script:Summary.ResourceCount | Should -Be 4
        $script:Summary.KeywordCount | Should -Be 5
        $script:Summary.Path | Should -Be $script:CachePath
    }

    It 'writes parseable JSON with format version 1' {
        $script:Cache | Should -Not -Be $null
        $script:Cache.formatVersion | Should -Be 1
        $script:Cache.module.name | Should -Be 'xTestClassResource'
        $script:Cache.module.version | Should -Be '1.0'
        @($script:Cache.keywords).Count | Should -Be 5
        $embedded = $script:Cache.keywords | Where-Object { $_.keyword -eq 'EmbClass' }
        $embedded.nameMode | Should -Be 'NoName'
    }

    It 'round-trips every keyword through ConvertFrom-DscKeywordSchemaObject' {
        foreach ($schemaObject in $script:Cache.keywords)
        {
            $keyword = ConvertFrom-PSDscKeywordSchemaObject -SchemaObject $schemaObject
            $keyword.Keyword | Should -Be $schemaObject.keyword
            $keyword.ResourceName | Should -Be $schemaObject.resourceName
            $keyword.ImplementingModule | Should -Be $schemaObject.implementingModule
            $keyword.NameMode.ToString() | Should -Be $schemaObject.nameMode
            $keyword.BodyMode.ToString() | Should -Be $schemaObject.bodyMode
            $keyword.Properties.Count | Should -Be @($schemaObject.properties.PSObject.Properties).Count
        }
    }

    It 'round-trips key, mandatory and value map details' {
        $schemaObject = $script:Cache.keywords | Where-Object { $_.keyword -eq 'xTestClassResource' }
        $keyword = ConvertFrom-PSDscKeywordSchemaObject -SchemaObject $schemaObject

        $keyword.Properties['Name'].IsKey | Should -Be $true
        $keyword.Properties['Name'].Mandatory | Should -Be $true
        $keyword.Properties['Value'].Mandatory | Should -Be $true

        (@($keyword.Properties['Ensure'].Values) -join ',') | Should -Be (@($schemaObject.properties.Ensure.values) -join ',')
        @($keyword.Properties['Ensure'].Values).Count | Should -Be 2
        $keyword.Properties['Ensure'].ValueMap.Count | Should -Be @($schemaObject.properties.Ensure.valueMap).Count
        $keyword.Properties['Ensure'].ValueMap['Present'] | Should -Be 'Present'
        $keyword.Properties['Ensure'].ValueMap['Absent'] | Should -Be 'Absent'
    }
}

Describe 'Test-DscSchemaCache' {
    BeforeAll {
        $copyRoot = Join-Path $TestDrive 'CopyMods'
        $null = New-Item -ItemType Directory -Path $copyRoot -Force
        Copy-Item -Path (Join-Path $script:PSDscTestRoot 'TestModules\xTestClassResource') -Destination $copyRoot -Recurse
        $script:CopyDirectory = Join-Path $copyRoot 'xTestClassResource'
        $copyModule = Get-Module -ListAvailable (Join-Path $script:CopyDirectory 'xTestClassResource.psd1')
        $script:CopyCachePath = Join-Path $TestDrive 'copy-cache.json'
        $null = Export-DscSchemaCache -Module $copyModule -OutputPath $script:CopyCachePath
    }

    It 'returns true for an untouched module' {
        Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $script:CopyCachePath | Should -Be $true
    }

    It 'returns false with a warning after the module content changed' {
        Add-Content -Path (Join-Path $script:CopyDirectory 'xTestClassResource.psm1') -Value '# drift marker'
        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $script:CopyCachePath -Detailed -WarningVariable warnings 3>$null
        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'changed since cache generation'
    }
}

Describe 'Stale schema cache handling in the fast host' {
    It 'warns about a stale cache and still compiles' {
        $doctoredPath = Join-Path $TestDrive 'doctored-cache.json'
        $null = Export-DscSchemaCache -ModuleName xTestClassResource -OutputPath $doctoredPath
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($doctoredPath))
        $cache.module.fingerprint = '1:1'
        $json = ConvertTo-Json -InputObject $cache -Depth 12 -Compress
        [System.IO.File]::WriteAllText($doctoredPath, $json)

        $text = @'
Configuration StaleCacheCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'stale'
        }
        ResourceForTests2 b
        {
            Prop1 = 'second'
        }
    }
}
'@
        $warnings = $null
        $result = Invoke-DscFastCompile -ScriptText $text -SchemaCachePath $doctoredPath -OutputPath (Join-Path $TestDrive 'stale-out') -WarningVariable warnings 3>$null
        ($warnings -join ' ') | Should -Match 'stale'
        $result.Exists | Should -Be $true
        $mofText = [System.IO.File]::ReadAllText($result.FullName)
        $mofText | Should -Match 'instance of ResourceForTests1'
        $mofText | Should -Match 'Prop1 = "stale"'
    }
}
