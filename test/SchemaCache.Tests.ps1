BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    function ConvertFrom-PSDscKeywordSchemaObject
    {
        param ($SchemaObject)

        Invoke-PSDscInEngineScope { ConvertFrom-DscKeywordSchemaObject -SchemaObject $args[0] } $SchemaObject
    }

    function Copy-PSDscTestModule
    {
        param ([string] $Name, [string] $Destination)

        $null = New-Item -ItemType Directory -Path $Destination -Force
        Copy-Item -Path (Join-Path $PSScriptRoot "TestModules\$Name") -Destination $Destination -Recurse -Force
        Join-Path $Destination $Name
    }
}

AfterAll {
    Restore-PSDscTestModulePath
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

    It 'records a source hash for every module file' {
        $files = @($script:Cache.module.sourceHash.PSObject.Properties)
        ($files.Name | Sort-Object) -join ',' | Should -Be 'xTestClassResource.psd1,xTestClassResource.psm1'
        foreach ($file in $files)
        {
            $file.Value | Should -Match '^[0-9A-F]{64}$'
        }
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

    It 'writes next to the module when no output path is given' {
        $modulePath = Copy-PSDscTestModule -Name xTestClassResource -Destination (Join-Path $TestDrive 'default-output')
        $module = Get-Module -ListAvailable (Join-Path $modulePath 'xTestClassResource.psd1')

        $summary = Export-DscSchemaCache -Module $module

        $summary.Path | Should -Be (Join-Path $modulePath 'DscSchemaCache.json')
        $summary.Path | Should -Exist
    }

    It 'creates the output directory when it does not exist' {
        $cachePath = Join-Path $TestDrive 'created\nested\cache.json'

        $null = Export-DscSchemaCache -ModuleName xTestClassResource -OutputPath $cachePath

        $cachePath | Should -Exist
    }

    It 'selects the requested module version' {
        $summary = Export-DscSchemaCache -ModuleName xTestClassResource -RequiredVersion '1.0' -OutputPath (Join-Path $TestDrive 'versioned-cache.json')

        $summary.ModuleVersion | Should -Be ([version]'1.0')
    }

    It 'throws when the requested module version is not installed' {
        { Export-DscSchemaCache -ModuleName xTestClassResource -RequiredVersion '99.0' -OutputPath (Join-Path $TestDrive 'missing-version.json') } |
            Should -Throw -ExpectedMessage "*version 99.0 was not found*"
    }

    It 'throws when the module is not installed' {
        { Export-DscSchemaCache -ModuleName 'xTestModuleThatDoesNotExist' -OutputPath (Join-Path $TestDrive 'missing-module.json') } |
            Should -Throw -ExpectedMessage "*was not found*"
    }
}

Describe 'Test-DscSchemaCache' {
    BeforeAll {
        $script:CopyDirectory = Copy-PSDscTestModule -Name xTestClassResource -Destination (Join-Path $TestDrive 'CopyMods')
        $copyModule = Get-Module -ListAvailable (Join-Path $script:CopyDirectory 'xTestClassResource.psd1')
        $script:CopyCachePath = Join-Path $TestDrive 'copy-cache.json'
        $null = Export-DscSchemaCache -Module $copyModule -OutputPath $script:CopyCachePath
    }

    It 'returns true for an untouched module' {
        Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $script:CopyCachePath | Should -Be $true
    }

    It 'accepts a manifest path instead of a module directory' {
        Test-DscSchemaCache -ModulePath (Join-Path $script:CopyDirectory 'xTestClassResource.psd1') -CachePath $script:CopyCachePath | Should -Be $true
    }

    It 'returns false with a warning when the cache file is missing' {
        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath (Join-Path $TestDrive 'absent-cache.json') -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'does not exist'
    }

    It 'returns false with a warning for a newer cache format' {
        $futurePath = Join-Path $TestDrive 'future-format.json'
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:CopyCachePath))
        $cache.formatVersion = 99
        [System.IO.File]::WriteAllText($futurePath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $futurePath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'newer than supported'
    }

    It 'returns false with a warning when the module version moved on' {
        $otherVersionPath = Join-Path $TestDrive 'other-version.json'
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:CopyCachePath))
        $cache.module.version = '9.9'
        [System.IO.File]::WriteAllText($otherVersionPath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $otherVersionPath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'manifest declares'
    }

    It 'returns false with a warning when a cached file was removed' {
        $removedFilePath = Join-Path $TestDrive 'removed-file.json'
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:CopyCachePath))
        Add-Member -InputObject $cache.module.sourceHash -MemberType NoteProperty -Name 'gone.psm1' -Value ('0' * 64)
        [System.IO.File]::WriteAllText($removedFilePath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $removedFilePath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'no longer exists'
    }

    It 'returns false with a warning after the module content changed' {
        Add-Content -Path (Join-Path $script:CopyDirectory 'xTestClassResource.psm1') -Value '# drift marker'
        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $script:CopyCachePath -Detailed -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'changed since cache generation'
    }
}

Describe 'Get-DscSchemaCache' {
    BeforeAll {
        $script:Module = Get-Module -ListAvailable -Name xTestClassResource | Select-Object -First 1
        $script:ValidCachePath = Join-Path $TestDrive 'lookup-valid.json'
        $null = Export-DscSchemaCache -Module $script:Module -OutputPath $script:ValidCachePath
    }

    It 'returns the cache from an explicitly named path' {
        $cache = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates
        } @{ Module = $script:Module; Candidates = @($script:ValidCachePath) }

        $cache.module.name | Should -Be 'xTestClassResource'
        @($cache.keywords).Count | Should -Be 5
    }

    It 'skips a candidate that is not valid JSON' {
        $brokenPath = Join-Path $TestDrive 'lookup-broken.json'
        [System.IO.File]::WriteAllText($brokenPath, '{ not json')

        $cache = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($brokenPath, $script:ValidCachePath) }

        $cache.module.name | Should -Be 'xTestClassResource'
    }

    It 'skips a candidate with an unsupported format version' {
        $futurePath = Join-Path $TestDrive 'lookup-future.json'
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:ValidCachePath))
        $cache.formatVersion = 99
        [System.IO.File]::WriteAllText($futurePath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($futurePath, $script:ValidCachePath) }

        $result.formatVersion | Should -Be 1
    }

    It 'skips a candidate that belongs to another module' {
        $otherModulePath = Join-Path $TestDrive 'lookup-other-module.json'
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($script:ValidCachePath))
        $cache.module.name = 'SomeOtherModule'
        [System.IO.File]::WriteAllText($otherModulePath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($otherModulePath, $script:ValidCachePath) }

        $result.module.name | Should -Be 'xTestClassResource'
    }

    It 'returns nothing when every candidate is stale' {
        # A copy with its own write times so no cache generated for the installed module can
        # satisfy the lookup through the module base or the per user location.
        $isolatedRoot = Copy-PSDscTestModule -Name xTestClassResource -Destination (Join-Path $TestDrive 'lookup-isolated')
        Add-Content -Path (Join-Path $isolatedRoot 'xTestClassResource.psm1') -Value '# isolated copy'
        $isolatedModule = Get-Module -ListAvailable (Join-Path $isolatedRoot 'xTestClassResource.psd1')

        $stalePath = Join-Path $TestDrive 'lookup-stale.json'
        $null = Export-DscSchemaCache -Module $isolatedModule -OutputPath $stalePath
        $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($stalePath))
        $cache.module.fingerprint = '1:1'
        [System.IO.File]::WriteAllText($stalePath, (ConvertTo-Json -InputObject $cache -Depth 12 -Compress))

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $isolatedModule; Candidates = @($stalePath) }

        $result | Should -BeNullOrEmpty
    }
}

Describe 'New-DscSchemaCacheForModule' {
    It 'generates and returns a cache in the per user location' {
        $moduleRoot = Join-Path $TestDrive 'generated-module'
        $null = New-Item -ItemType Directory -Path $moduleRoot -Force
        Copy-Item -Path (Join-Path $PSScriptRoot 'TestModules\xTestClassResource') -Destination $moduleRoot -Recurse -Force
        $module = Get-Module -ListAvailable (Join-Path $moduleRoot 'xTestClassResource\xTestClassResource.psd1')

        $userPath = Invoke-PSDscInEngineScope {
            Get-DscSchemaCacheUserPath -ModuleName $args[0].Name -ModuleVersion $args[0].Version -Fingerprint (Get-DscModuleFingerprint -Module $args[0])
        } $module

        try
        {
            $cache = Invoke-PSDscInEngineScope { New-DscSchemaCacheForModule -Module $args[0] } $module

            $userPath | Should -Exist
            $cache.module.name | Should -Be 'xTestClassResource'
            @($cache.keywords).Count | Should -Be 5
        }
        finally
        {
            Remove-Item -Path $userPath -Force -ErrorAction Ignore
        }
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
