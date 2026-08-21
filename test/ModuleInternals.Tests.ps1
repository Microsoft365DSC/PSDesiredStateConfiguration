BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    function Invoke-PSDscStringify
    {
        param ($Value, [bool] $AsArray = $false, [type] $TargetType = [string])

        # stringify reads the alias table of the instance being rendered out of its caller
        # scope, which is ConvertTo-MOFInstance during a real compilation.
        Invoke-PSDscInEngineScope {
            $InstanceAliases = @{}
            stringify $args[0] $args[1] $args[2]
        } @($Value, $AsArray, $TargetType)
    }
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'stringify' {
    It 'quotes a string' {
        Invoke-PSDscStringify -Value 'plain' | Should -BeExactly '"plain"'
    }

    It 'escapes backslashes, quotes and line breaks' {
        Invoke-PSDscStringify -Value "a\b`"c`r`nd" | Should -BeExactly '"a\\b\"c\nd"'
    }

    It 'renders a null value as NULL' {
        Invoke-PSDscStringify -Value $null | Should -BeExactly 'NULL'
    }

    It 'casts a non string value to the declared string type' {
        Invoke-PSDscStringify -Value 42 | Should -BeExactly '"42"'
    }

    It 'always gives a real a decimal point' {
        Invoke-PSDscStringify -Value 3 -TargetType ([double]) | Should -BeExactly '3.0'
        Invoke-PSDscStringify -Value 3.5 -TargetType ([double]) | Should -BeExactly '3.5'
    }

    It 'single quotes a char' {
        Invoke-PSDscStringify -Value 'A' -TargetType ([char]) | Should -BeExactly "'A'"
    }

    It 'keeps the width of the integer target type' {
        Invoke-PSDscStringify -Value '-9223372036854775808' -TargetType ([int64]) | Should -BeExactly '-9223372036854775808'
        Invoke-PSDscStringify -Value '18446744073709551615' -TargetType ([uint64]) | Should -BeExactly '18446744073709551615'
    }

    It 'renders a boolean' {
        Invoke-PSDscStringify -Value $true -TargetType ([bool]) | Should -BeExactly 'True'
    }

    It 'refuses to convert a string to a boolean' {
        { Invoke-PSDscStringify -Value 'true' -TargetType ([bool]) } |
            Should -Throw -ExpectedMessage '*Boolean parameters accept only Boolean values*'
    }

    It 'renders an array as a MOF brace list' {
        Invoke-PSDscStringify -Value @('a', 'b') | Should -BeExactly "{`n    `"a`",`n    `"b`"`n}"
    }

    It 'renders a single value as an array when asked to' {
        Invoke-PSDscStringify -Value 'a' -AsArray $true | Should -BeExactly "{`n    `"a`"`n}"
    }

    It 'renders an empty array' {
        Invoke-PSDscStringify -Value @() -AsArray $true | Should -BeExactly "{`n}"
    }
}

Describe 'ConvertTo-MofDateTimeString' {
    It 'renders a DMTF datetime string' {
        $result = Invoke-PSDscInEngineScope { ConvertTo-MofDateTimeString $args[0] } ([datetime]'2021-03-04T05:06:07.123456')

        $result | Should -Match '^20210304050607\.123456[+-][0-9]{3}$'
    }
}

Describe 'Get-DscModuleFingerprint' {
    BeforeAll {
        $script:FingerprintRoot = Join-Path $TestDrive 'fingerprint'
        $null = New-Item -ItemType Directory -Path $script:FingerprintRoot -Force
        Copy-Item -Path (Join-Path $PSScriptRoot 'TestModules\xTestClassResource') -Destination $script:FingerprintRoot -Recurse -Force
        $script:FingerprintModule = Get-Module -ListAvailable (Join-Path $script:FingerprintRoot 'xTestClassResource\xTestClassResource.psd1')
    }

    It 'counts the module files and takes the newest write time' {
        $fingerprint = Invoke-PSDscInEngineScope { Get-DscModuleFingerprint -Module $args[0] } $script:FingerprintModule

        $fingerprint | Should -Match '^2:[0-9]+$'
    }

    It 'changes when a module file is touched' {
        $before = Invoke-PSDscInEngineScope { Get-DscModuleFingerprint -Module $args[0] } $script:FingerprintModule
        Add-Content -Path (Join-Path $script:FingerprintRoot 'xTestClassResource\xTestClassResource.psm1') -Value '# touched'
        $after = Invoke-PSDscInEngineScope { Get-DscModuleFingerprint -Module $args[0] } $script:FingerprintModule

        $after | Should -Not -Be $before
    }
}

Describe 'Get-DscSchemaCacheUserPath' {
    It 'builds a per user path with the fingerprint colon replaced' {
        $path = Invoke-PSDscInEngineScope {
            Get-DscSchemaCacheUserPath -ModuleName $args[0] -ModuleVersion $args[1] -Fingerprint $args[2]
        } @('SomeModule', [version]'2.3', '4:12345')

        Split-Path -Path $path -Leaf | Should -BeExactly 'SomeModule_2.3_4_12345.json'
        $path | Should -BeLike '*M365DSC.PSDesiredStateConfiguration*SchemaCache*'
    }
}

Describe 'Get-CompatibleVersionAdditionalPropertiesString' {
    It 'returns one string with every property quoted' {
        $result = Invoke-PSDscInEngineScope {
            $script:PSMetaConfigDocumentInstVersionInfo = @{ CompatibleVersionAdditionalProperties = @('First:one', 'Second:two') }
            Get-CompatibleVersionAdditionalPropertiesString
        }

        $result | Should -BeOfType ([System.String])
        $result | Should -BeExactly '{"First:one", "Second:two"}'
    }

    It 'returns an empty brace pair when nothing is recorded' {
        $result = Invoke-PSDscInEngineScope {
            $script:PSMetaConfigDocumentInstVersionInfo = @{}
            Get-CompatibleVersionAdditionalPropertiesString
        }

        $result | Should -BeExactly '{}'
    }
}

Describe 'Test-ModuleReloadRequired' {
    BeforeAll {
        $script:SchemaRoot = Join-Path $TestDrive 'composite-schema'
        $null = New-Item -ItemType Directory -Path $script:SchemaRoot -Force
        $script:SchemaFile = Join-Path $script:SchemaRoot 'xProbe.schema.psm1'
        Set-Content -Path $script:SchemaFile -Value 'Configuration xProbe { }' -Encoding Ascii
    }

    It 'ignores a path that is not a composite schema' {
        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } (Join-Path $script:SchemaRoot 'xProbe.psm1') |
            Should -Be $false
    }

    It 'ignores a composite schema that does not exist' {
        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } (Join-Path $script:SchemaRoot 'gone.schema.psm1') |
            Should -Be $false
    }

    It 'requires a reload the first time and not again' {
        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $script:SchemaFile | Should -Be $true
        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $script:SchemaFile | Should -Be $false
    }

    It 'requires a reload again after the schema changed' {
        $null = Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $script:SchemaFile
        (Get-Item -Path $script:SchemaFile).LastWriteTime = (Get-Date).AddMinutes(1)

        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $script:SchemaFile | Should -Be $true
    }

    It 'forgets a schema file that was removed' {
        $temporarySchema = Join-Path $script:SchemaRoot 'xTemporary.schema.psm1'
        Set-Content -Path $temporarySchema -Value 'Configuration xTemporary { }' -Encoding Ascii
        $null = Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $temporarySchema
        Remove-Item -Path $temporarySchema -Force

        Invoke-PSDscInEngineScope { Test-ModuleReloadRequired -SchemaFilePath $args[0] } $temporarySchema | Should -Be $false
        Invoke-PSDscInEngineScope { $script:schemaFileLastUpdate.ContainsKey($args[0]) } $temporarySchema | Should -Be $false
    }
}

Describe 'WriteFile' {
    It 'writes the value without adding a line break' {
        $path = Join-Path $TestDrive 'written.txt'

        Invoke-PSDscInEngineScope { WriteFile -Path $args[0] -Value $args[1] } @($path, 'content')

        [System.IO.File]::ReadAllText($path) | Should -BeExactly 'content'
    }

    It 'reports a path it cannot write to' {
        $path = Join-Path $TestDrive 'missing-directory\written.txt'

        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-PSDscInEngineScope { WriteFile -Path $args[0] -Value $args[1] } @($path, 'content')
        }

        $diagnostics | Should -Match 'Error Reading file'
        $path | Should -Not -Exist
    }
}

Describe 'ReadEnvironmentFile' {
    It 'evaluates a restricted language data file' {
        $path = Join-Path $TestDrive 'environment.psd1'
        Set-Content -Path $path -Encoding Ascii -Value @'
@{
    AllNodes = @(
        @{ NodeName = 'localhost'; Role = 'Web' }
    )
}
'@

        $data = Invoke-PSDscInEngineScope { ReadEnvironmentFile -FilePath $args[0] } $path

        $data.AllNodes[0].NodeName | Should -Be 'localhost'
        $data.AllNodes[0].Role | Should -Be 'Web'
    }
}

Describe 'Reset-DscKeywordState' {
    It 'clears the cached dynamic keywords' {
        $null = Get-DscResource -Module xTestClassResource

        Invoke-PSDscInEngineScope { Reset-DscKeywordState }

        [System.Management.Automation.Language.DynamicKeyword]::GetKeyword('ResourceForTests1') | Should -BeNullOrEmpty
    }
}
