# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force

    # Compiled configurations resolve resource modules by name through PSModulePath.
    Add-PSDscTestModulePath
    Import-PSDscEngine

    $script:OriginalProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
}

AfterAll {
    $global:ProgressPreference = $script:OriginalProgressPreference
    Restore-PSDscTestModulePath
}

Describe 'Test M365DSC.PSDesiredStateConfiguration' {
    Context 'Module loading' {
        BeforeAll {
            $script:engine = Get-Module -Name M365DSC.PSDesiredStateConfiguration | Select-Object -First 1
        }

        It 'The module should be loaded exactly once' {
            @(Get-Module -Name M365DSC.PSDesiredStateConfiguration).Count | Should -Be 1
        }

        It 'The module should export the <CommandName> command' -TestCases @(
            @{ CommandName = 'Configuration' }
            @{ CommandName = 'New-DscChecksum' }
            @{ CommandName = 'Get-DscResource' }
            @{ CommandName = 'Invoke-DscResource' }
            @{ CommandName = 'Invoke-DscFastCompile' }
            @{ CommandName = 'Export-DscSchemaCache' }
            @{ CommandName = 'Test-DscSchemaCache' }
        ) {
            $script:engine.ExportedFunctions.Keys | Should -Contain $CommandName
        }

        It 'The <CommandName> command should be callable by name' -TestCases @(
            @{ CommandName = 'Configuration' }
            @{ CommandName = 'New-DscChecksum' }
            @{ CommandName = 'Get-DscResource' }
            @{ CommandName = 'Invoke-DscResource' }
            @{ CommandName = 'Invoke-DscFastCompile' }
            @{ CommandName = 'Export-DscSchemaCache' }
            @{ CommandName = 'Test-DscSchemaCache' }
        ) {
            Get-Command -Name $CommandName -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'The module should export exactly what its manifest promises' {
            $manifest = Import-PowerShellDataFile -Path (Get-PSDscEngineManifest)

            ($script:engine.ExportedFunctions.Keys | Sort-Object) -join ',' |
                Should -Be ((@($manifest.FunctionsToExport) | Sort-Object) -join ',')
        }

        It 'The module should claim the engine resolved Configuration name' {
            (Get-Command -Name 'PSDesiredStateConfiguration\Configuration').Module.Name |
                Should -Be 'M365DSC.PSDesiredStateConfiguration'
        }
    }

    Context 'Get-DscResource - Class base Resources' {
        BeforeDiscovery {
            $classTestCases = @(
                @{
                    TestCaseName = 'Good case'
                    Name         = 'xTestClassResource'
                    ModuleName   = 'xTestClassResource'
                }
                @{
                    TestCaseName = 'Module Name case mismatch'
                    Name         = 'xTestClassResource'
                    ModuleName   = 'xtestclassresource'
                }
                @{
                    TestCaseName = 'Resource name case mismatch'
                    Name         = 'XTESTCLASSRESOURCE'
                    ModuleName   = 'xTestClassResource'
                }
            )
        }

        It 'should be able to get class resource - <Name> from <ModuleName> - <TestCaseName>' -TestCases $classTestCases {
            $resource = Get-DscResource -Name $Name -Module $ModuleName
            $resource | Should -Not -BeNullOrEmpty
            $resource.Name | Should -Be 'xTestClassResource'
            $resource.ImplementationDetail | Should -Be 'ClassBased'
        }

        It 'should be able to get a class resource without naming its module' {
            $resource = Get-DscResource -Name 'xtestclassresource'
            $resource | Should -Not -BeNullOrEmpty
            $resource.Name | Should -Be 'xTestClassResource'
            $resource.ImplementationDetail | Should -Be 'ClassBased'
        }
    }
}

Describe 'DSC MOF Compilation' {
    It 'Should be able to compile a MOF using configuration keyword' {
        # -OutputPath must be a provider (filesystem) path: Write-MofDocumentFile resolves
        # the path with System.IO and does not understand PSDrive paths like TestDrive:\.
        [Scriptblock]::Create(@"
configuration DSCTestConfig
{
    Import-DscResource -ModuleName xTestClassResource
    Node "localhost" {
        ResourceForTests1 f1
        {
            Prop1 = 'testvalue'
        }
    }
}

DSCTestConfig -OutputPath '$TestDrive\DscTestConfig2'
"@) | Should -Not -Throw

        Test-Path (Join-Path $TestDrive 'DscTestConfig2\localhost.mof') | Should -BeTrue
    }
}

Describe 'All types DSC resource tests' {
    It 'Check all property types in Get-DscResource' {
        $resource = Get-DscResource -Module xTestClassResource | Where-Object { $_.Name -eq 'xTestClassResource' }
        $resource | Should -Not -BeNullOrEmpty
        # 34 declared properties + the OMI_BaseResource common properties DependsOn and PsDscRunAsCredential
        $resource.Properties.Count | Should -Be 36

        foreach ($dscResourcePropertyInfo in $resource.Properties)
        {
            switch ($dscResourcePropertyInfo.Name)
            {
                'Name' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string]' }
                'Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string]' }
                'Settings' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string]' }
                'bValue' { $dscResourcePropertyInfo.PropertyType | Should -Be '[bool]' }
                'sArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string[]]' }
                'bValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[bool[]]' }
                'char16Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[char]' }
                'char16ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[char[]]' }
                'dateTimeVal' { $dscResourcePropertyInfo.PropertyType | Should -Be '[DateTime]' }
                'dateTimeArrayVal' { $dscResourcePropertyInfo.PropertyType | Should -Be '[DateTime[]]' }
                'DependsOn' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string[]]' }
                'EmbClassObj' { $dscResourcePropertyInfo.PropertyType | Should -Be '[EmbClass]' }
                'EmbClassObjArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[EmbClass[]]' }
                'Ensure' { $dscResourcePropertyInfo.PropertyType | Should -Be '[string]' }
                'PsDscRunAsCredential' { $dscResourcePropertyInfo.PropertyType | Should -Be '[PSCredential]' }
                'Real32Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Single]' }
                'Real32ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Single[]]' }
                'Real64Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[double]' }
                'Real64ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[double[]]' }

                'sInt8Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[SByte]' }
                'sInt8ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[SByte[]]' }
                'sInt16Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Int16]' }
                'sInt16ValueArray' {
                    # Known defect on Windows PowerShell 5.1: the inbox DscClassCache
                    # (GAC System.Management.Automation) reports [Int16[]] class properties
                    # as [int64[]]; AddDscResourceProperty consumes that verbatim.
                    # Assertion therefore only runs on PowerShell 7+.
                    if ($PSVersionTable.PSEdition -ne 'Desktop')
                    {
                        $dscResourcePropertyInfo.PropertyType | Should -Be '[Int16[]]'
                    }
                }
                'sInt32Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Int32]' }
                'sInt32ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Int32[]]' }
                'sInt64Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Int64]' }
                'sInt64ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Int64[]]' }

                'uInt8Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Byte]' }
                'uInt8ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Byte[]]' }
                'uInt16Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt16]' }
                'uInt16ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt16[]]' }
                'uInt32Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt32]' }
                'uInt32ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt32[]]' }
                'uInt64Value' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt64]' }
                'uInt64ValueArray' { $dscResourcePropertyInfo.PropertyType | Should -Be '[UInt64[]]' }

                'HashTableValue' { $dscResourcePropertyInfo.PropertyType | Should -Be '[Hashtable]' }
            }
        }
    }

    It 'Check all property types in Invoke-DscResource' {
        $resource = Invoke-DscResource -Name xTestClassResource -ModuleName xTestClassResource -Method Get -Property @{Name = 'Test' }
        $resource | Should -Not -BeNullOrEmpty
        $resource.GetType().Name | Should -Be 'xTestClassResource'
        $resource.Name | Should -Be 'Test'
        $resource.Value | Should -Be 'Inside if'

        $resource.Name.GetType().Name | Should -Be 'String'
        $resource.Value.GetType().Name | Should -Be 'String'
        $resource.sArray.GetType().Name | Should -Be 'String[]'

        $resource.bValue.GetType().Name | Should -Be 'Boolean'
        $resource.bValueArray.GetType().Name | Should -Be 'Boolean[]'
        $resource.char16Value.GetType().Name | Should -Be 'Char'
        $resource.char16ValueArray.GetType().Name | Should -Be 'Char[]'
        $resource.dateTimeVal.GetType().Name | Should -Be 'DateTime'
        $resource.dateTimeArrayVal.GetType().Name | Should -Be 'DateTime[]'
        $resource.EmbClassObj.GetType().Name | Should -Be 'EmbClass'
        $resource.EmbClassObjArray.GetType().Name | Should -Be 'EmbClass[]'
        $resource.Ensure.GetType().Name | Should -Be 'Ensure'
        $resource.Real32Value.GetType().Name | Should -Be 'Single'
        $resource.Real32ValueArray.GetType().Name | Should -Be 'Single[]'
        $resource.Real64Value.GetType().Name | Should -Be 'Double'
        $resource.Real64ValueArray.GetType().Name | Should -Be 'Double[]'

        $resource.sInt8Value.GetType().Name | Should -Be 'SByte'
        $resource.sInt8ValueArray.GetType().Name | Should -Be 'SByte[]'
        $resource.sInt16Value.GetType().Name | Should -Be 'Int16'
        $resource.sInt16ValueArray.GetType().Name | Should -Be 'Int16[]'
        $resource.sInt32Value.GetType().Name | Should -Be 'Int32'
        $resource.sInt32ValueArray.GetType().Name | Should -Be 'Int32[]'
        $resource.sInt64Value.GetType().Name | Should -Be 'Int64'
        $resource.sInt64ValueArray.GetType().Name | Should -Be 'Int64[]'

        $resource.uInt8Value.GetType().Name | Should -Be 'Byte'
        $resource.uInt8ValueArray.GetType().Name | Should -Be 'Byte[]'
        $resource.uInt16Value.GetType().Name | Should -Be 'UInt16'
        $resource.uInt16ValueArray.GetType().Name | Should -Be 'UInt16[]'
        $resource.uInt32Value.GetType().Name | Should -Be 'UInt32'
        $resource.uInt32ValueArray.GetType().Name | Should -Be 'UInt32[]'
        $resource.uInt64Value.GetType().Name | Should -Be 'UInt64'
        $resource.uInt64ValueArray.GetType().Name | Should -Be 'UInt64[]'

        $resource.HashTableValue.GetType().Name | Should -Be 'Hashtable'

        # extra check for embedded objects
        $resource.EmbClassObj.EmbClassStr1 | Should -Be 'TestEmbObjValue'
        $resource.EmbClassObjArray[0].EmbClassStr1 | Should -Be 'TestEmbClassStr1Value'
    }

    It 'Check all property types in configuration compilation' {
        [Scriptblock]::Create(@"
configuration DSCAllTypesConfig
{
    Import-DscResource -ModuleName xTestClassResource
    Node "localhost" {
        xTestClassResource f1
        {
            Name = 'TestName'
            Value = 'TestValue'

            char16Value = 'A'
            char16ValueArray = @('A','B')

            sArray = @('Test1','Test2')

            bValue = `$true
            bValueArray = @(`$true,`$false)

            dateTimeVal = Get-Date
            dateTimeArrayVal = @(`$(Get-Date), `$(Get-Date))

            Ensure = 'Present'

            uInt8Value = 255
            sInt8Value = -128
            uInt16Value = 65535
            sInt16Value = -32768
            uInt32Value = 4294967295
            sInt32Value = -2147483648
            uInt64Value = 18446744073709551615
            sInt64Value = -9223372036854775808

            Real32Value = [Single]-1.234
            Real64Value = [Double]-1.234

            uInt8ValueArray = @(255)
            sInt8ValueArray = @(-128)
            uInt16ValueArray = @(65535)
            sInt16ValueArray = @(-32768)
            uInt32ValueArray = @(4294967295)
            sInt32ValueArray = @(-2147483648)
            uInt64ValueArray = @(18446744073709551615)
            sInt64ValueArray = @(-9223372036854775808)

            HashTableValue = @{
                Key1 = 'Value1'
                Key2 = 'Value2'
            }
        }
    }
}

DSCAllTypesConfig -OutputPath '$TestDrive\DSCAllTypesConfig'
"@) | Should -Not -Throw

        Test-Path (Join-Path $TestDrive 'DSCAllTypesConfig\localhost.mof') | Should -BeTrue

        $mofContent = Get-Content -Raw -Path (Join-Path $TestDrive 'DSCAllTypesConfig\localhost.mof')
        $mofContent | Should -Match 'uInt64Value = 18446744073709551615;'
        $mofContent | Should -Match 'sInt64Value = -9223372036854775808;'
        $mofContent | Should -Match 'Real64Value = -1.234;'
        $mofContent | Should -Match "char16Value = 'A';"
        $mofContent | Should -Match 'instance of MSFT_KeyValuePair'
    }

    It 'Check multi-resource configuration compilation with dependencies' {
        [Scriptblock]::Create(@"
configuration MultiResourceConfig
{
    Import-DscResource -ModuleName xTestClassResource
    ResourceForTests1 r1
    {
        Prop1 = 'Test'
    }
    ResourceForTests2 r2
    {
        Prop1 = 'Test'
        DependsOn = '[ResourceForTests1]r1'
    }
    ResourceForTests3 r3
    {
        Prop1 = 'Test'
        DependsOn = '[ResourceForTests1]r1','[ResourceForTests2]r2'
    }
}

MultiResourceConfig -OutputPath '$TestDrive\MultiResourceConfig'
"@) | Should -Not -Throw

        Test-Path (Join-Path $TestDrive 'MultiResourceConfig\localhost.mof') | Should -BeTrue

        $mofContent = Get-Content -Raw -Path (Join-Path $TestDrive 'MultiResourceConfig\localhost.mof')
        $mofContent | Should -Match 'DependsOn = \{\s*"\[ResourceForTests1\]r1",\s*"\[ResourceForTests2\]r2"\s*\}'
    }

    It 'Check empty array compilation' {
        [Scriptblock]::Create(@"
configuration DSCEmptyArrayConfig
{
    Import-DscResource -ModuleName xTestClassResource
    Node "localhost" {
        xTestClassResource f2
        {
            Name = 'TestName'
            Value = 'TestValue'

            sArray = @()
        }
    }
}

DSCEmptyArrayConfig -OutputPath '$TestDrive\DSCEmptyArrayConfig'
"@) | Should -Not -Throw

        Test-Path (Join-Path $TestDrive 'DSCEmptyArrayConfig\localhost.mof') | Should -BeTrue

        # MOF content is emitted with LF line endings
        $mofContent = Get-Content -Raw -Path (Join-Path $TestDrive 'DSCEmptyArrayConfig\localhost.mof')
        $mofContent -match '\ssArray\s=\s\{\n\};' | Should -BeTrue
    }
}
