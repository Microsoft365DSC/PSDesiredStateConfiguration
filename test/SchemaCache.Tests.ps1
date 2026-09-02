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

    function Read-PSDscCacheHeader
    {
        param ([string] $Path)

        ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllLines($Path)[0])
    }

    function Read-PSDscCacheSource
    {
        param ([string] $Path)

        ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllLines($Path)[1])
    }

    function Read-PSDscCacheKeyword
    {
        param ([string] $Path)

        $lines = [System.IO.File]::ReadAllLines($Path)
        for ($i = 2; $i -lt $lines.Count; $i++)
        {
            ConvertFrom-Json -InputObject $lines[$i]
        }
    }

    function Copy-PSDscCacheWithLine
    {
        param ([string] $Source, [string] $Destination, [int] $Index, [scriptblock] $Mutate)

        $lines = [System.IO.File]::ReadAllLines($Source)
        $object = ConvertFrom-Json -InputObject $lines[$Index]
        & $Mutate $object
        $lines[$Index] = ConvertTo-Json -InputObject $object -Depth 12 -Compress
        [System.IO.File]::WriteAllLines($Destination, $lines)
    }

    function Get-PSDscCacheKeywordCount
    {
        param ($Cache)

        @(Invoke-PSDscInEngineScope { Get-DscSchemaCacheKeywordName -Cache $args[0] } $Cache).Count
    }
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'Export-DscSchemaCache' {
    BeforeAll {
        $script:CachePath = Join-Path $TestDrive 'xTestClassResource-cache.json'
        $script:Summary = Export-DscSchemaCache -ModuleName xTestClassResource -OutputPath $script:CachePath
        $script:Header = Read-PSDscCacheHeader -Path $script:CachePath
        $script:Keywords = @(Read-PSDscCacheKeyword -Path $script:CachePath)
    }

    It 'returns a summary with 4 resources and 5 keywords' {
        $script:Summary.ModuleName | Should -Be 'xTestClassResource'
        $script:Summary.ModuleVersion | Should -Be ([version]'1.0')
        $script:Summary.ResourceCount | Should -Be 4
        $script:Summary.KeywordCount | Should -Be 5
        $script:Summary.Path | Should -Be $script:CachePath
    }

    It 'writes a header line with format version 2 and a keyword index' {
        $script:Header.formatVersion | Should -Be 2
        $script:Header.module.name | Should -Be 'xTestClassResource'
        $script:Header.module.version | Should -Be '1.0'
        $script:Header.keywordCount | Should -Be 5
        $script:Header.resourceCount | Should -Be 4
        @($script:Header.index.PSObject.Properties).Count | Should -Be 5
    }

    It 'writes one keyword per line at the indexed position' {
        $script:Keywords.Count | Should -Be 5
        $lines = [System.IO.File]::ReadAllLines($script:CachePath)
        foreach ($entry in $script:Header.index.PSObject.Properties)
        {
            (ConvertFrom-Json -InputObject $lines[[int]$entry.Value]).keyword | Should -Be $entry.Name
        }
        $embedded = $script:Keywords | Where-Object { $_.keyword -eq 'EmbClass' }
        $embedded.nameMode | Should -Be 'NoName'
    }

    It 'records size and hash for every module file on the source line' {
        $files = @((Read-PSDscCacheSource -Path $script:CachePath).PSObject.Properties)
        ($files.Name | Sort-Object) -join ',' | Should -Be 'xTestClassResource.psd1,xTestClassResource.psm1'
        foreach ($file in $files)
        {
            $file.Value.sha256 | Should -Match '^[0-9A-F]{64}$'
            $file.Value.length | Should -BeGreaterThan 0
        }
    }

    It 'fingerprints file count, total bytes and a size hash' {
        $script:Header.module.fingerprint | Should -Match '^2:[0-9]+:[0-9a-f]{16}$'
    }

    It 'round-trips every keyword through ConvertFrom-DscKeywordSchemaObject' {
        foreach ($schemaObject in $script:Keywords)
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
        $schemaObject = $script:Keywords | Where-Object { $_.keyword -eq 'xTestClassResource' }
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

    It 'includes the keywords of schema based resources' {
        $summary = Export-DscSchemaCache -ModuleName xTestScriptResource -OutputPath (Join-Path $TestDrive 'script-cache.json')

        $summary.ResourceCount | Should -Be 1
        $summary.KeywordCount | Should -BeGreaterOrEqual 1
        $keywords = @(Read-PSDscCacheKeyword -Path $summary.Path)
        ($keywords | Where-Object { $_.keyword -eq 'xTestScriptResource' }).resourceName | Should -Be 'MSFT_xTestScriptResource'
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

    It 'returns false with a warning for another cache format' {
        $futurePath = Join-Path $TestDrive 'future-format.json'
        Copy-PSDscCacheWithLine -Source $script:CopyCachePath -Destination $futurePath -Index 0 -Mutate { $args[0].formatVersion = 99 }

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $futurePath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'not the supported version'
    }

    It 'returns false with a warning for a single line file' {
        $singleLinePath = Join-Path $TestDrive 'single-line.json'
        [System.IO.File]::WriteAllText($singleLinePath, '{"formatVersion":2}')

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $singleLinePath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'could not be read'
    }

    It 'returns false with a warning when the module version moved on' {
        $otherVersionPath = Join-Path $TestDrive 'other-version.json'
        Copy-PSDscCacheWithLine -Source $script:CopyCachePath -Destination $otherVersionPath -Index 0 -Mutate { $args[0].module.version = '9.9' }

        $warnings = $null
        $result = Test-DscSchemaCache -ModulePath $script:CopyDirectory -CachePath $otherVersionPath -WarningVariable warnings 3>$null

        $result | Should -Be $false
        ($warnings -join ' ') | Should -Match 'manifest declares'
    }

    It 'returns false with a warning when a cached file was removed' {
        $removedFilePath = Join-Path $TestDrive 'removed-file.json'
        Copy-PSDscCacheWithLine -Source $script:CopyCachePath -Destination $removedFilePath -Index 1 -Mutate {
            Add-Member -InputObject $args[0] -MemberType NoteProperty -Name 'gone.psm1' -Value ([pscustomobject]@{ length = 1; sha256 = ('0' * 64) })
        }

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
        $cache.keywordCount | Should -Be 5
        Get-PSDscCacheKeywordCount -Cache $cache | Should -Be 5
    }

    It 'accepts a module descriptor with Name, Version and ModuleBase' {
        $descriptor = [pscustomobject]@{
            Name       = $script:Module.Name
            Version    = $script:Module.Version
            ModuleBase = $script:Module.ModuleBase
            Path       = $script:Module.Path
        }

        $cache = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates
        } @{ Module = $descriptor; Candidates = @($script:ValidCachePath) }

        $cache.module.name | Should -Be 'xTestClassResource'
    }

    It 'deserializes a keyword on request and reports null for an unknown name' {
        $cache = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates
        } @{ Module = $script:Module; Candidates = @($script:ValidCachePath) }

        $keyword = Invoke-PSDscInEngineScope { Get-DscSchemaCacheKeyword -Cache $args[0] -Name 'xtestclassresource' } $cache
        $keyword | Should -BeOfType ([System.Management.Automation.Language.DynamicKeyword])
        $keyword.Keyword | Should -Be 'xTestClassResource'
        Invoke-PSDscInEngineScope { Get-DscSchemaCacheKeyword -Cache $args[0] -Name 'NoSuchKeyword' } $cache | Should -BeNullOrEmpty
    }

    It 'skips a candidate that is not valid JSON' {
        $brokenPath = Join-Path $TestDrive 'lookup-broken.json'
        [System.IO.File]::WriteAllText($brokenPath, "{ not json`n{")

        $cache = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($brokenPath, $script:ValidCachePath) }

        $cache.module.name | Should -Be 'xTestClassResource'
    }

    It 'skips a candidate with another format version' {
        $futurePath = Join-Path $TestDrive 'lookup-future.json'
        Copy-PSDscCacheWithLine -Source $script:ValidCachePath -Destination $futurePath -Index 0 -Mutate { $args[0].formatVersion = 99 }

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($futurePath, $script:ValidCachePath) }

        $result.formatVersion | Should -Be 2
        $result.Path | Should -Be $script:ValidCachePath
    }

    It 'skips a candidate that belongs to another module' {
        $otherModulePath = Join-Path $TestDrive 'lookup-other-module.json'
        Copy-PSDscCacheWithLine -Source $script:ValidCachePath -Destination $otherModulePath -Index 0 -Mutate { $args[0].module.name = 'SomeOtherModule' }

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $script:Module; Candidates = @($otherModulePath, $script:ValidCachePath) }

        $result.module.name | Should -Be 'xTestClassResource'
    }

    It 'returns nothing when every candidate is stale' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.7' `
            -Destination (Join-Path $TestDrive 'lookup-isolated')
        $isolatedModule = $isolated.Module

        $stalePath = Join-Path $TestDrive 'lookup-stale.json'
        $null = Export-DscSchemaCache -Module $isolatedModule -OutputPath $stalePath
        Copy-PSDscCacheWithLine -Source $stalePath -Destination $stalePath -Index 0 -Mutate { $args[0].module.fingerprint = '1:1:0000000000000000' }

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $isolatedModule; Candidates = @($stalePath) }

        $result | Should -BeNullOrEmpty
    }

    It 'does not warn about a stale candidate' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.9' `
            -Destination (Join-Path $TestDrive 'lookup-no-warning')

        $stalePath = Join-Path $TestDrive 'lookup-no-warning.json'
        $null = Export-DscSchemaCache -Module $isolated.Module -OutputPath $stalePath
        Copy-PSDscCacheWithLine -Source $stalePath -Destination $stalePath -Index 0 -Mutate { $args[0].module.fingerprint = '1:1:0000000000000000' }

        $streams = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates
        } @{ Module = $isolated.Module; Candidates = @($stalePath) } 3>&1

        @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) | Should -BeNullOrEmpty
    }

    It 'returns the cache when a file appeared after the cache was generated' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '2.0' `
            -Destination (Join-Path $TestDrive 'lookup-extra-file')

        $cachePath = Join-Path $TestDrive 'lookup-extra-file.json'
        $null = Export-DscSchemaCache -Module $isolated.Module -OutputPath $cachePath

        Set-Content -Path (Join-Path $isolated.Module.ModuleBase 'Leftover.psm1') -Value 'function Get-Leftover { }'

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $isolated.Module; Candidates = @($cachePath) }

        $result.module.name | Should -Be 'xTestClassResource'
        $result.keywordCount | Should -Be 5
    }

    It 'returns the cache after the module files were copied with new write times' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '2.2' `
            -Destination (Join-Path $TestDrive 'lookup-copied')

        $cachePath = Join-Path $TestDrive 'lookup-copied.json'
        $null = Export-DscSchemaCache -Module $isolated.Module -OutputPath $cachePath

        foreach ($file in Get-ChildItem -Path $isolated.Module.ModuleBase -File)
        {
            $file.LastWriteTimeUtc = [datetime]::UtcNow.AddDays(1)
        }

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $isolated.Module; Candidates = @($cachePath) }

        $result.module.name | Should -Be 'xTestClassResource'
    }

    It 'returns nothing when a recorded file no longer exists' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '2.1' `
            -Destination (Join-Path $TestDrive 'lookup-missing-file')

        $cachePath = Join-Path $TestDrive 'lookup-missing-file.json'
        $null = Export-DscSchemaCache -Module $isolated.Module -OutputPath $cachePath

        Remove-Item -Path (Join-Path $isolated.Module.ModuleBase 'xTestClassResource.psm1') -Force

        $result = Invoke-PSDscInEngineScope {
            Get-DscSchemaCache -Module $args[0].Module -SchemaCachePath $args[0].Candidates -WarningAction SilentlyContinue
        } @{ Module = $isolated.Module; Candidates = @($cachePath) }

        $result | Should -BeNullOrEmpty
    }
}

Describe 'New-DscSchemaCacheForModule' {
    It 'generates and returns a cache in the per user location' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.5' `
            -Destination (Join-Path $TestDrive 'generated-module')

        try
        {
            $isolated.UserCachePath | Should -Not -Exist

            $cache = Invoke-PSDscInEngineScope { New-DscSchemaCacheForModule -Module $args[0] } @($isolated.Module)

            $isolated.UserCachePath | Should -Exist
            $cache.module.name | Should -Be 'xTestClassResource'
            $cache.keywordCount | Should -Be 5
        }
        finally
        {
            Remove-Item -Path $isolated.UserCachePath -Force -ErrorAction Ignore
        }
    }

    It 'resolves a module descriptor to the module for discovery' {
        $isolated = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.6' `
            -Destination (Join-Path $TestDrive 'generated-descriptor')
        $descriptor = [pscustomobject]@{
            Name       = $isolated.Module.Name
            Version    = $isolated.Module.Version
            ModuleBase = $isolated.Module.ModuleBase
            Path       = $isolated.ManifestPath
        }

        try
        {
            $cache = Invoke-PSDscInEngineScope { New-DscSchemaCacheForModule -Module $args[0] } @($descriptor)

            $isolated.UserCachePath | Should -Exist
            $cache.keywordCount | Should -Be 5
        }
        finally
        {
            Remove-Item -Path $isolated.UserCachePath -Force -ErrorAction Ignore
        }
    }
}

Describe 'Stale schema cache handling in the fast host' {
    BeforeAll {
        $script:StaleModule = New-PSDscIsolatedTestModule -Name xTestClassResource -Version '1.8' `
            -Destination (Join-Path $TestDrive 'stale-cache-module')
        $script:StaleOriginalModulePath = $env:PSModulePath
        $env:PSModulePath = $script:StaleModule.Root + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Reset-PSDscFastHostState
    }

    AfterAll {
        Remove-Item -Path $script:StaleModule.UserCachePath -Force -ErrorAction Ignore
        $env:PSModulePath = $script:StaleOriginalModulePath
        Reset-PSDscFastHostState
    }

    It 'compiles without warning when the cache is stale' {
        $doctoredPath = Join-Path $TestDrive 'doctored-cache.json'
        $null = Export-DscSchemaCache -Module $script:StaleModule.Module -OutputPath $doctoredPath
        Copy-PSDscCacheWithLine -Source $doctoredPath -Destination $doctoredPath -Index 0 -Mutate { $args[0].module.fingerprint = '1:1:0000000000000000' }
        $script:StaleModule.UserCachePath | Should -Not -Exist

        $text = @'
Configuration StaleCacheCfg
{
    Import-DscResource -ModuleName xTestClassResource -ModuleVersion '1.8'
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

        $warnings | Should -BeNullOrEmpty
        $result.Exists | Should -Be $true
        $mofText = [System.IO.File]::ReadAllText($result.FullName)
        $mofText | Should -Match 'instance of ResourceForTests1'
        $mofText | Should -Match 'Prop1 = "stale"'
    }

    It 'regenerated the cache it could not use' {
        $script:StaleModule.UserCachePath | Should -Exist
    }
}
