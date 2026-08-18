BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    function Invoke-PSDscStringifyValue
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

Describe 'stringify edge cases' {
    It 'casts a value to a non string target type' {
        Invoke-PSDscStringifyValue -Value 42 -TargetType ([int32]) | Should -BeExactly '42'
    }

    It 'renders a script block that uses $using: variables from the caller scope' {
        $probe = 'from-caller'
        $scriptBlock = { $using:probe }

        $result = Invoke-PSDscInEngineScope { $InstanceAliases = @{}; stringify $args[0] } $scriptBlock

        $result | Should -Match 'from-caller'
    }

    It 'renders a script block that uses $using: variables from its defining module' {
        $probeModule = New-Module -Name 'ProbeStringifyModule' -ScriptBlock {
            $script:inner = 'module-value'
            function Get-ProbeScriptBlock { { $using:inner } }
        }
        $scriptBlock = & $probeModule { Get-ProbeScriptBlock }

        $result = Invoke-PSDscInEngineScope { $InstanceAliases = @{}; stringify $args[0] } $scriptBlock

        $result | Should -Match 'module-value'
    }

    It 'looks up $using: variables in the caller scope when the script block has no defining module' {
        $probe = 'from-caller'
        $scriptBlock = [scriptblock]::Create('$using:probe')

        $result = Invoke-PSDscInEngineScope { $InstanceAliases = @{}; stringify $args[0] } $scriptBlock

        $result | Should -BeExactly '"$probe"'
    }

    It 'serializes non string $using: variables from the defining module' {
        $probeModule = New-Module -Name 'ProbeStringifyModuleInt' -ScriptBlock {
            $script:inner = 42
            function Get-ProbeScriptBlock { { $using:inner } }
        }
        $scriptBlock = & $probeModule { Get-ProbeScriptBlock }

        $result = Invoke-PSDscInEngineScope { $InstanceAliases = @{}; stringify $args[0] } $scriptBlock

        $result | Should -Match 'PSSerializer]::Deserialize'
    }
}

Describe 'Meta configuration version bookkeeping' {
    BeforeEach {
        Invoke-PSDscInEngineScope {
            $script:PSMetaConfigDocumentInstVersionInfo = @{}
            $script:PSMetaConfigDocInsProcessedBeforeMeta = $false
            $script:PSMetaConfigurationProcessed = $false
        }
    }

    It 'raises the minimum version for a property outside the V1 list' {
        $versionInfo = Invoke-PSDscInEngineScope {
            Generate-VersionInfo -KeywordData @{ PsDscRunAsCredential = $null } -Value @{ PsDscRunAsCredential = $null }
            Get-PSMetaConfigDocumentInstVersionInfo
        }

        $versionInfo['MinimumCompatibleVersion'] | Should -BeExactly '2.0.0'
    }

    It 'keeps version 1.0.0 for V1 properties only and records the additional property' {
        $versionInfo = Invoke-PSDscInEngineScope {
            Generate-VersionInfo -KeywordData @{ ConfigurationMode = $null } -Value @{ ConfigurationMode = 'ApplyOnly' }
            Get-PSMetaConfigDocumentInstVersionInfo
        }

        $versionInfo['MinimumCompatibleVersion'] | Should -BeExactly '1.0.0'
        @($versionInfo['CompatibleVersionAdditionalProperties']) -contains 'MSFT_DSCMetaConfiguration:StatusRetentionTimeInDays' | Should -Be $true
        Invoke-PSDscInEngineScope { Get-PSMetaConfigurationProcessed } | Should -Be $true
    }

    It 'records that the configuration document was processed before the meta configuration' {
        Invoke-PSDscInEngineScope {
            Set-PSMetaConfigDocInsProcessedBeforeMeta
            $script:PSMetaConfigDocInsProcessedBeforeMeta
        } | Should -Be $true
    }

    It 'updates the document instance when it was processed before the meta configuration' {
        $text = Invoke-PSDscInEngineScope {
            $script:PSMetaConfigDocInsProcessedBeforeMeta = $true
            $script:NoNameNodeInstanceAliases = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:NoNameNodeInstanceAliases['$OMI_ConfigurationDocument1ref'] = "instance of MSFT_DSCMetaConfiguration`n{`nMinimumCompatibleVersion = `"1.0.0`"`n};"
            $script:PSDefaultConfigurationDocument = 'old text'
            Set-PSMetaConfigVersionInfoV2
            Get-MofInstanceText '$OMI_ConfigurationDocument1ref'
        }

        $text | Should -Match 'MinimumCompatibleVersion = "2.0.0"'
        Invoke-PSDscInEngineScope { Get-PSDefaultConfigurationDocument } | Should -Match 'MinimumCompatibleVersion = "2.0.0"'
    }
}

Describe 'Default configuration document' {
    It 'stores and returns the default configuration document text' {
        Invoke-PSDscInEngineScope {
            Set-PSDefaultConfigurationDocument 'document text'
            Get-PSDefaultConfigurationDocument
        } | Should -BeExactly 'document text'
    }
}

Describe 'Get-PositionInfo' {
    It 'returns an empty string when there is no source metadata' {
        Invoke-PSDscInEngineScope { Get-PositionInfo } | Should -BeExactly ''
    }

    It 'formats the source metadata location' {
        $position = Invoke-PSDscInEngineScope { Get-PositionInfo -sourceMetadata $args[0] } 'probe.ps1::3::7::my text here'

        $position | Should -Match 'probe.ps1:3 char:7'
        $position | Should -Match 'my text here'
    }
}

Describe 'Get-MofInstanceText' {
    It 'reads the instance text of the current node' {
        $text = Invoke-PSDscInEngineScope {
            $script:NodeInstanceAliases = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.Dictionary[string,string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Set-PSCurrentConfigurationNode 'probe'
            $script:NodeInstanceAliases['probe'] = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:NodeInstanceAliases['probe']['$alias1ref'] = 'instance of Probe { }'
            Get-MofInstanceText '$alias1ref'
        }

        $text | Should -Match 'instance of Probe'
    }

    It 'reads the unnamed node instance text when no node is current' {
        $text = Invoke-PSDscInEngineScope {
            $script:NoNameNodeInstanceAliases = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Set-PSCurrentConfigurationNode $null
            $script:NoNameNodeInstanceAliases['$alias2ref'] = 'instance of Nope { }'
            Get-MofInstanceText '$alias2ref'
        }

        $text | Should -Match 'instance of Nope'
    }
}

Describe 'Get-ComplexResourceQualifier' {
    It 'joins the qualifier chain including the current node' {
        $qualifier = Invoke-PSDscInEngineScope {
            # The engine keeps the enclosing configuration names in a List[string] that
            # survives between configurations, so fill it in place and empty it again.
            $script:ConfigurationNestingStack.Clear()
            $script:ConfigurationNestingStack.AddRange([string[]]@('a', 'b', 'c'))
            $qualifier = Get-ComplexResourceQualifier -IncludeCurrent
            $script:ConfigurationNestingStack.Clear()
            $qualifier
        }

        $qualifier | Should -BeExactly 'c::b'
    }

    It 'joins the qualifier chain excluding the current node' {
        $qualifier = Invoke-PSDscInEngineScope {
            $script:ConfigurationNestingStack.Clear()
            $script:ConfigurationNestingStack.AddRange([string[]]@('a', 'b', 'c'))
            $qualifier = Get-ComplexResourceQualifier
            $script:ConfigurationNestingStack.Clear()
            $qualifier
        }

        $qualifier | Should -BeExactly 'b'
    }

    It 'returns null when the nesting stack is too shallow' {
        $qualifier = Invoke-PSDscInEngineScope {
            $script:ConfigurationNestingStack.Clear()
            $script:ConfigurationNestingStack.Add('a')
            $qualifier = Get-ComplexResourceQualifier
            $script:ConfigurationNestingStack.Clear()
            $qualifier
        }

        $qualifier | Should -BeNullOrEmpty
    }
}

Describe 'Per node resource bookkeeping' {
    It 'reports no resources before the resource table exists' {
        Invoke-PSDscInEngineScope { $script:NodeResources = $null; Test-NodeResources -resourceId 'res' } | Should -Be $false
    }

    It 'creates the resource table on demand' {
        $present = Invoke-PSDscInEngineScope {
            $script:NodeResources = $null
            Set-NodeResources -resourceId 'res' -requiredResourceList @('dep')
            Test-NodeResources -resourceId 'res'
        }

        $present | Should -Be $true
    }

    It 'reports no managers before the manager table exists' {
        Invoke-PSDscInEngineScope { $script:NodeManager = $null; Test-NodeManager -resourceId 'res' } | Should -Be $false
    }

    It 'creates the manager table on demand' {
        $present = Invoke-PSDscInEngineScope {
            $script:NodeManager = $null
            Set-NodeManager -resourceId 'res' -referencedManagers @('PullServer')
            Test-NodeManager -resourceId 'res'
        }

        $present | Should -Be $true
    }

    It 'reports no sources before the resource source table exists' {
        Invoke-PSDscInEngineScope { $script:NodeResourceSource = $null; Test-NodeResourceSource -resourceId 'res' } | Should -Be $false
    }

    It 'creates the resource source table on demand' {
        $present = Invoke-PSDscInEngineScope {
            $script:NodeResourceSource = $null
            Set-NodeResourceSource -resourceId 'res' -referencedResourceSources @('Local')
            Test-NodeResourceSource -resourceId 'res'
        }

        $present | Should -Be $true
    }

    It 'creates the node keys table on demand and de-duplicates keys' {
        $keys = Invoke-PSDscInEngineScope {
            $script:NodeKeys = $null
            Add-NodeKeys -ResourceKey 'k1' -keywordName 'kw'
            Add-NodeKeys -ResourceKey 'k1' -keywordName 'kw'
            Add-NodeKeys -ResourceKey 'k2' -keywordName 'kw'
            @($script:NodeKeys['kw']) -join ','
        }

        $keys | Should -BeExactly 'k1,k2'
    }
}

Describe 'Update-ModuleVersion' {
    It 'inserts the engine version into a PsDesiredStateConfiguration resource' {
        $updated = Invoke-PSDscInEngineScope {
            $script:ExplicitlyImportedModules = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:ExplicitlyImportedModules['PsDesiredStateConfiguration'] = '1.0.0.0'
            $script:PsDscModuleVersion = '2.0.0.0'

            $nodeResources = [System.Collections.Generic.Dictionary[string,string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $nodeResources['res1'] = @()
            $aliases = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $aliases['$X1ref'] = "instance of X`n{`n ModuleName = `"PsDesiredStateConfiguration`"`n};"
            $resourceAliases = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $resourceAliases['res1'] = '$X1ref'

            Update-ModuleVersion -NodeResources $nodeResources -NodeInstanceAliases $aliases -NodeResourceIdAliases $resourceAliases
            $aliases['$X1ref']
        }

        $updated | Should -Match 'ModuleVersion = "2.0.0.0"'
    }
}

Describe 'ReadEnvironmentFile' {
    It 'reports a data file path that cannot be resolved' {
        $missingPath = Join-Path $TestDrive 'missing-directory\environment.psd1'

        $exception = { Invoke-PSDscInEngineScope { $ErrorActionPreference = 'Stop'; ReadEnvironmentFile -FilePath $args[0] } $missingPath } |
            Should -Throw -PassThru
        $exception.Exception.Message | Should -Match 'environment data file path'
    }

    It 'reports environment data that cannot be evaluated' {
        $path = Join-Path $TestDrive 'broken.psd1'
        Set-Content -Path $path -Value '@{ x = }' -Encoding Ascii

        $errorVariable = $null
        $delta = Invoke-PSDscInEngineScope {
            $ErrorActionPreference = 'SilentlyContinue'
            $before = Get-ConfigurationErrorCount
            ReadEnvironmentFile -FilePath $args[0]
            (Get-ConfigurationErrorCount) - $before
        } $path -ErrorVariable errorVariable

        $delta | Should -Be 1
        $report = $errorVariable | Where-Object { $_.FullyQualifiedErrorId -like 'InvalidEnvironmentContentSpecified*' } | Select-Object -First 1
        $report | Should -Not -BeNullOrEmpty
        $report.Exception.Message | Should -Match 'broken.psd1'
    }
}

Describe 'Node and credential compilation branches' {
    It 'reuses the per-node runtime state when the same node is declared twice' {
        $text = @'
configuration DupNodeCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
    Node localhost
    {
        ResourceForTests1 b
        {
            Prop1 = 'y'
        }
    }
}
'@
        Invoke-Expression -Command $text

        $result = DupNodeCfg -OutputPath (Join-Path $TestDrive 'dup-node')

        @($result.FullName | Where-Object { $_ -match 'localhost\.mof$' }).Count | Should -BeGreaterThan 0
    }

    It 'matches per-node data for a credential in a multi-node statement' {
        $text = @'
configuration MultiNodeCredCfg
{
    param
    (
        [PSCredential]
        $Credential
    )

    Import-DscResource -ModuleName xTestCredentialResource
    Node @('localhost', 'second')
    {
        xTestCredentialResource a
        {
            Name = 'secret-holder'
            Credential = $Credential
        }
    }
}
'@
        Invoke-Expression -Command $text

        $credential = [PSCredential]::new('localuser', (ConvertTo-SecureString -String 'Pl41nT3xtP@ss' -AsPlainText -Force))
        $result = MultiNodeCredCfg -Credential $credential -OutputPath (Join-Path $TestDrive 'multi-node') `
            -ConfigurationData @{ AllNodes = @(
                @{ NodeName = 'localhost'; PSDscAllowPlainTextPassword = $true }
                @{ NodeName = 'second';    PSDscAllowPlainTextPassword = $true }
            ) }

        @($result.FullName | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'localhost.mof'
        @($result.FullName | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'second.mof'
    }

    It 'rejects a credential used outside a node statement when no node data can be found' {
        $text = @'
configuration NoNodeCredCfg
{
    param
    (
        [PSCredential]
        $Credential
    )

    Import-DscResource -ModuleName xTestCredentialResource
    xTestCredentialResource a
    {
        Name = 'secret-holder'
        Credential = $Credential
    }
}
'@
        Invoke-Expression -Command $text

        $diagnostics = Get-PSDscDiagnosticText {
            $credential = [PSCredential]::new('localuser', (ConvertTo-SecureString -String 'Pl41nT3xtP@ss' -AsPlainText -Force))
            NoNodeCredCfg -Credential $credential -OutputPath (Join-Path $TestDrive 'no-node-cred')
        }

        $diagnostics | Should -Match 'storing encrypted passwords as plain text is not recommended'
    }
}

Describe 'Coverage: engine compilation branches' {
    It 'compiles a resource imported by name without an explicit module' {
        $text = @'
configuration BareNameCfg
{
    Import-DscResource -Name ResourceForTests1
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'bare-name'
        $result = Invoke-PSDscConfigurationText -Text $text -Name BareNameCfg -OutputPath $outputPath

        $result.Exists | Should -Be $true
    }

    It 'compiles a composite resource configuration' {
        $text = @'
configuration CompositeOuterCfg
{
    Import-DscResource -ModuleName xTestCompositeResource
    Node localhost
    {
        xTestComposite c
        {
            Marker = 'x'
        }
    }
}
'@
        $outputPath = Join-Path $TestDrive 'composite'
        $result = Invoke-PSDscConfigurationText -Text $text -Name CompositeOuterCfg -OutputPath $outputPath

        $result.Exists | Should -Be $true
    }

    It 'writes the output under the configuration name when no output path is given' {
        $text = @'
configuration NoOutputCfg
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
        Invoke-Expression -Command $text

        Push-Location $TestDrive
        try
        {
            NoOutputCfg | Out-Null
        }
        finally
        {
            Pop-Location
        }

        Test-Path -LiteralPath (Join-Path $TestDrive 'NoOutputCfg\localhost.mof') | Should -Be $true
    }

    It 'reports an output path that cannot be created' {
        $text = @'
configuration BadOutputCfg
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
        $blocker = Join-Path $TestDrive 'blocker-file'
        Set-Content -Path $blocker -Value 'not a directory'

        Invoke-Expression -Command $text

        $diagnostics = Get-PSDscDiagnosticText {
            BadOutputCfg -OutputPath (Join-Path $blocker 'sub')
        }

        $diagnostics | Should -Match 'Could not find a part of the path'
    }

    It 'rejects an invalid configuration name' {
        { Invoke-PSDscInEngineScope {
            $ErrorActionPreference = 'Stop'
            & ${function:Configuration} -Name '1bad name' -Body { } -OutputPath (Join-Path $args[0] 'bad-name')
        } $TestDrive } | Should -Throw
    }

    It 'returns the module for the built-in MSFT_LogResource schema' {
        $moduleRoot = Join-Path $TestDrive 'log-resource-module'
        $null = New-Item -ItemType Directory -Path (Join-Path $moduleRoot 'DscResources\MSFT_LogResource') -Force
        Set-Content -Path (Join-Path $moduleRoot 'LogResModule.psd1') -Value '@{ RootModule = ''LogResModule.psm1''; ModuleVersion = ''1.0'' }'
        Set-Content -Path (Join-Path $moduleRoot 'LogResModule.psm1') -Value ''
        Set-Content -Path (Join-Path $moduleRoot 'DscResources\MSFT_LogResource\MSFT_LogResource.schema.mof') -Value 'class MSFT_LogResource : OMI_BaseResource { [string] Message; };'
        Import-Module -Name (Join-Path $moduleRoot 'LogResModule.psd1') -Force

        try
        {
            $module = Invoke-PSDscInEngineScope {
                GetModule -modules $args[0] -schemaFileName $args[1]
            } @((Get-Module LogResModule), (Join-Path $moduleRoot 'DscResources\MSFT_LogResource\MSFT_LogResource.schema.mof'))

            $module.Name | Should -Be 'LogResModule'
        }
        finally
        {
            Remove-Module -Name LogResModule -Force -ErrorAction Ignore
        }
    }

    It 'warns when built-in resources are used without an explicit module import' {
        $text = @'
configuration BuiltinLogCfg
{
    Node localhost
    {
        Log l
        {
            Message = 'hello built-in log'
        }
    }
}
'@
        Invoke-Expression -Command $text

        $warnings = & {
            BuiltinLogCfg -OutputPath (Join-Path $TestDrive 'builtin-log')
        } 3>&1

        (@($warnings) -join ' ') | Should -Match 'built-in resources without explicitly importing'
    }

    It 'reports conflicting resources that differ in which properties are set' {
        $text = @'
configuration PropertySetDiffCfg
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource first
        {
            Name = 'shared-key'
            Value = 'one'
            bValue = $false
        }
        xTestClassResource second
        {
            Name = 'shared-key'
            Value = 'one'
            Ensure = 'Present'
        }
        xTestClassResource third
        {
            Name = 'shared-key'
            Value = 'one'
            bValue = $true
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name PropertySetDiffCfg -OutputPath (Join-Path $TestDrive 'property-set-diff')

        $diagnostics | Should -Match 'A conflict was detected between resources'
        $diagnostics | Should -Match 'Ensure'
    }

    It 'reports a module wildcard declared before the named resource it covers' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration WildcardFirstExclusiveCfg
{
    Node localhost
    {
        PartialConfiguration Partial1
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\*')
        }
        PartialConfiguration Partial2
        {
            RefreshMode = 'Push'
            ExclusiveResources = @('xTestClassResource\ResourceForTests1')
        }
    }
}
'@
        $diagnostics = Get-PSDscCompilationDiagnostic -Text $text -Name WildcardFirstExclusiveCfg -OutputPath (Join-Path $TestDrive 'wildcard-first-exclusive')

        $diagnostics | Should -Match 'coflicting exclusive resource declarations'
    }
}

Describe 'Get-PublicKeyFromStore' {
    It 'returns the certificate from the machine store when the thumbprint matches' {
        $certificates = @(Get-ChildItem -Path cert:\LocalMachine\My -ErrorAction SilentlyContinue)

        if ($certificates.Count -eq 0)
        {
            Set-ItResult -Skipped -Because 'no certificates are installed in LocalMachine\My'
        }
        else
        {
            $cert = Invoke-PSDscInEngineScope { Get-PublicKeyFromStore -certificateid $args[0] } $certificates[0].Thumbprint

            $cert.Thumbprint | Should -Be $certificates[0].Thumbprint
        }
    }
}

Describe 'Test-MofInstanceText' {
    It 'returns a message when the instance text does not validate' {
        $message = Invoke-PSDscInEngineScope {
            $script:FastHostActive = $false
            Test-MofInstanceText -instanceText 'instance of totally broken {{'
        }

        $message | Should -Not -BeNullOrEmpty
        $message | Should -Match 'Syntax error'
    }
}

Describe 'GetImplementingModulePath' {
    It 'returns the sibling module file of the schema' {
        $moduleRoot = Join-Path $TestDrive 'implementing-module'
        $null = New-Item -ItemType Directory -Path $moduleRoot -Force
        $schemaFile = Join-Path $moduleRoot 'X.schema.mof'
        Set-Content -Path $schemaFile -Value '' -Encoding Ascii
        Set-Content -Path (Join-Path $moduleRoot 'X.psd1') -Value '' -Encoding Ascii

        $result = Invoke-PSDscInEngineScope { GetImplementingModulePath -schemaFileName $args[0] } $schemaFile

        $result | Should -BeExactly (Join-Path $moduleRoot 'X.psd1')
    }
}

Describe 'GetModule' {
    It 'returns null for a file that is not a schema' {
        $module = Get-Module M365DSC.PSDesiredStateConfiguration

        Invoke-PSDscInEngineScope { GetModule -modules $args[0] -schemaFileName $args[1] } @($module, 'foo.ps1') |
            Should -BeNullOrEmpty
    }
}

Describe 'Get-EncryptedPassword' {
    It 'passes the value through when no node data is present' {
        Invoke-PSDscInEngineScope { Get-EncryptedPassword -Value 'secret' } | Should -BeExactly 'secret'
    }

    It 'finds the current node in an array of node data' {
        $value = Invoke-PSDscInEngineScope {
            $Node = 'probe'
            $selectedNodesData = @(@{ NodeName = 'other'; X = 1 }, @{ NodeName = 'probe'; X = 2 })
            $allnodes = $null
            Get-EncryptedPassword -Value 'secret'
        }

        $value | Should -BeExactly 'secret'
    }

    It 'finds a localhost node in the AllNodes data' {
        $value = Invoke-PSDscInEngineScope {
            $Node = $null
            $selectedNodesData = $null
            $allnodes = @{ AllNodes = @(@{ NodeName = 'localhost'; X = 1 }) }
            Get-EncryptedPassword -Value 'secret'
        }

        $value | Should -BeExactly 'secret'
    }
}

Describe 'ValidateNodeResources' {
    It 'expands a DependsOn reference that matches a resource by name suffix' {
        $expanded = Invoke-PSDscInEngineScope {
            $script:NodeResources = [System.Collections.Generic.Dictionary[string,string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:NodeResources['MyModule\\resource'] = @()
            $script:NodeResources['Second'] = @('resource')
            ValidateNodeResources
            ($script:NodeResources['Second'] -join ',')
        }

        $expanded | Should -BeExactly 'MyModule\\resource'
    }
}

Describe 'Coverage: CIM keyword implementation branches' {
    BeforeAll {
        function New-PSDscCimFakeCache {
            param([string]$Destination)
            $module = Get-Module -ListAvailable -Name xTestClassResource | Sort-Object Version -Descending | Select-Object -First 1
            $real = Join-Path $Destination 'real.json'
            Export-DscSchemaCache -Module $module -OutputPath $real | Out-Null
            $cache = Get-Content -Raw $real | ConvertFrom-Json
            function Add-PSDscFakeKeyword($cache, $keyword, $resourceName, $nameMode, $props) {
                $properties = @{}
                foreach ($p in $props) {
                    $properties[$p.name] = @{
                        name           = $p.name
                        typeConstraint = $p.typeConstraint
                        mandatory      = $p.mandatory
                        isKey          = $p.isKey
                        attributes     = @()
                        values         = @($p.values)
                        valueMap       = @($p.valueMap)
                    }
                }
                $cache.keywords += [PSCustomObject]@{
                    keyword                   = $keyword
                    resourceName              = $resourceName
                    implementingModule        = $null
                    implementingModuleVersion = $null
                    nameMode                  = $nameMode
                    bodyMode                  = 'ScriptBlock'
                    directCall                = $false
                    metaStatement             = $false
                    properties                = $properties
                }
            }
            Add-PSDscFakeKeyword $cache 'FakePlainKeyword' 'FakePlainClass' 'SimpleOptionalName' @(
                @{ name = 'NoDependsOn'; typeConstraint = 'string'; mandatory = $false; isKey = $false; values = @(); valueMap = @() }
            )
            Add-PSDscFakeKeyword $cache 'FakeValueMapKeyword' 'FakeValueMapClass' 'NameRequired' @(
                @{ name = 'DependsOn'; typeConstraint = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = @() },
                @{ name = 'State'; typeConstraint = 'string'; mandatory = $false; isKey = $false; values = @('On', 'Off'); valueMap = @(@{ key = 'On'; value = 'Enabled' }, @{ key = 'Off'; value = 'Disabled' }) }
            )
            $fake = Join-Path $Destination 'fake.json'
            $cache | ConvertTo-Json -Depth 12 | Set-Content $fake
            $fake
        }
    }

    AfterAll {
        Reset-PSDscFastHostState
    }

    It 'propagates a composite DependsOn and qualifies nested resource ids' {
        $text = @'
configuration CompDep
{
    Import-DscResource -ModuleName xTestClassResource
    Import-DscResource -ModuleName xTestCompositeResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
        xTestComposite c
        {
            Marker = 'x'
            DependsOn = '[ResourceForTests1]a'
        }
    }
}
'@
        $result = Invoke-PSDscConfigurationText -Text $text -Name CompDep -OutputPath (Join-Path $TestDrive 'comp-dep')
        $content = Get-Content -Raw $result.FullName

        $content | Should -Match '\[ResourceForTests1\]comp::\[xTestComposite\]c'
        $content | Should -Match 'DependsOn = \{\s*"\[ResourceForTests1\]a"\s*\}'
    }

    It 'rejects V2-only properties in an old-style LocalConfigurationManager block' {
        $text = @'
configuration OldMetaCfg
{
    Node localhost
    {
        LocalConfigurationManager
        {
            RefreshMode = 'Push'
            StatusRetentionTimeInDays = 5
        }
    }
}
'@
        $diagnostic = Get-PSDscCompilationDiagnostic -Text $text -Name OldMetaCfg -OutputPath (Join-Path $TestDrive 'old-meta')

        $diagnostic | Should -Match 'StatusRetentionTimeInDays'
        $diagnostic | Should -Match 'cannot be specified in LocalConfigurationManager'
    }

    It 'rejects a DebugMode with more than one value' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MetaDebug
{
    Node localhost
    {
        Settings
        {
            DebugMode = @('ForceModuleImport','All')
        }
    }
}
'@
        $diagnostic = Get-PSDscCompilationDiagnostic -Text $text -Name MetaDebug -OutputPath (Join-Path $TestDrive 'meta-debug')

        $diagnostic | Should -Match 'DebugMode should only have one value'
    }

    It 'rejects a null value for an enum-restricted meta property' {
        $text = @'
[DSCLocalConfigurationManager()]
configuration MetaNullRefresh
{
    Node localhost
    {
        Settings
        {
            RefreshMode = $null
        }
    }
}
'@
        $diagnostic = Get-PSDscCompilationDiagnostic -Text $text -Name MetaNullRefresh -OutputPath (Join-Path $TestDrive 'meta-null-refresh')

        $diagnostic | Should -Match 'RefreshMode'
    }

    It 'flows PsDscRunAsCredential from a composite into its nested resources' {
        $text = @'
configuration CompCred
{
    param([PSCredential]$RunAs)
    Import-DscResource -ModuleName xTestClassResource
    Import-DscResource -ModuleName xTestCompositeResource
    Node localhost
    {
        xTestComposite c
        {
            Marker = 'x'
            PsDscRunAsCredential = $RunAs
        }
    }
}
'@
        $credential = [PSCredential]::new('dscuser', (ConvertTo-SecureString 'Pl41nT3xtP@ss' -AsPlainText -Force))
        Invoke-Expression -Command $text

        { & CompCred -RunAs $credential -OutputPath (Join-Path $TestDrive 'comp-cred') 2>$null } | Should -Throw
    }

    It 'validates a well-formed DependsOn reference through the fast host' {
        $text = @'
configuration FastDepOk
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
        ResourceForTests2 b
        {
            Prop1 = 'y'
            DependsOn = '[ResourceForTests1]a'
        }
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-dep-ok') -NoFallback 2>$null
        $result.Exists | Should -Be $true
    }

    It 'rejects a malformed DependsOn reference through the fast host' {
        $text = @'
configuration FastDepBad
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            DependsOn = @('garbage-reference')
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-dep-bad') -NoFallback 2>$null } | Should -Throw
    }

    It 'rejects a duplicate resource instance through the fast host' {
        $text = @'
configuration FastDup
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
        }
        ResourceForTests1 a
        {
            Prop1 = 'z'
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-dup') -NoFallback 2>$null } | Should -Throw
    }

    It 'accepts an enum value that is in the allowed list through the fast host' {
        $text = @'
configuration FastEnumOk
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'n1'
            Value = 'v'
            Ensure = 'Present'
        }
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-enum-ok') -NoFallback 2>$null
        $result.Exists | Should -Be $true
    }

    It 'rejects an enum value that is not in the allowed list through the fast host' {
        $text = @'
configuration FastEnumBad
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'n1'
            Value = 'v'
            Ensure = 'Bogus'
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-enum-bad') -NoFallback 2>$null } | Should -Throw
    }

    It 'rejects a null value for an enum-restricted property through the fast host' {
        $text = @'
configuration FastEnsureNull
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'n1'
            Value = 'v'
            Ensure = $null
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-ensure-null') -NoFallback 2>$null } | Should -Throw
    }

    It 'rejects a missing value for a mandatory property through the fast host' {
        $text = @'
configuration FastMissingMandatory
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r1
        {
            Name = 'n1'
        }
    }
}
'@
        { Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-missing-mandatory') -NoFallback 2>$null } | Should -Throw
    }

    It 'compiles a resource whose key property is null through the fast host' {
        $text = @'
configuration FastKeyNull
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        xTestClassResource r2
        {
            Name = $null
            Value = 'v'
        }
    }
}
'@
        $result = Invoke-DscFastCompile -ScriptText $text -OutputPath (Join-Path $TestDrive 'fast-key-null') -NoFallback 2>$null
        $result.Exists | Should -Be $true
    }

    It 'handles a non-resource keyword and a ValueMap through a crafted cache' {
        Reset-PSDscFastHostState
        $fakeCache = New-PSDscCimFakeCache $TestDrive
        $plain = @'
configuration FastFakePlain
{
    Import-DscResource -ModuleName xTestClassResource
    FakePlainKeyword marker
    {
        NoDependsOn = 'x'
    }
}
'@
        $valueMap = @'
configuration FastFakeValueMap
{
    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        FakeValueMapKeyword v
        {
            State = 'On'
        }
    }
}
'@
        $r1 = Invoke-DscFastCompile -ScriptText $plain -OutputPath (Join-Path $TestDrive 'fast-fake-plain') -SchemaCachePath $fakeCache -NoFallback 2>$null
        $r1.Exists | Should -Be $true
        $r2 = Invoke-DscFastCompile -ScriptText $valueMap -OutputPath (Join-Path $TestDrive 'fast-fake-value-map') -SchemaCachePath $fakeCache -NoFallback 2>$null
        $r2.Exists | Should -Be $true
    }
}

Describe 'Coverage: CIM keyword implementation via direct invocation' {
    BeforeAll {
        function Invoke-PSDscCimDirect {
            param(
                [string]$Keyword,
                [string]$ResourceName,
                [string]$NameMode,
                [string]$ImplementingModule,
                [hashtable]$Props,
                [hashtable]$Value,
                [string]$Name = '',
                [hashtable]$Driver
            )

            $sb = {
                param($kKeyword, $kResourceName, $kNameMode, $kImplementingModule, $kProps, $kValue, $kName, $kDriver, $kSource)
                Initialize-ConfigurationRuntimeState
                Set-PSCurrentConfigurationNode $kDriver.node
                if ($null -ne $kDriver.node) {
                    $script:NodeInstanceAliases[$kDriver.node] = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $script:NodeResourceIdAliases[$kDriver.node] = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                $script:ConfigurationNestingStack.Clear()
                foreach ($e in @($kDriver.nesting)) { $script:ConfigurationNestingStack.Add([string]$e) }
                $script:FastHostKeywords = @{}
                $script:IsMetaConfig = [bool]$kDriver.isMetaConfig
                if ($kDriver.metaDocProcessed) { $script:PSMetaConfigurationProcessed = $true }

                $k = New-Object System.Management.Automation.Language.DynamicKeyword
                $k.Keyword = $kKeyword
                $k.ResourceName = $kResourceName
                $k.NameMode = [System.Management.Automation.Language.DynamicKeywordNameMode]::$kNameMode
                $k.BodyMode = [System.Management.Automation.Language.DynamicKeywordBodyMode]::ScriptBlock
                $k.ImplementingModule = $kImplementingModule
                foreach ($pn in $kProps.Keys) {
                    $p = New-Object System.Management.Automation.Language.DynamicKeywordProperty
                    $p.Name = $pn
                    $p.TypeConstraint = $kProps[$pn].type
                    $p.Mandatory = [bool]$kProps[$pn].mandatory
                    $p.IsKey = [bool]$kProps[$pn].isKey
                    foreach ($v in @($kProps[$pn].values)) { $null = $p.Values.Add([string]$v) }
                    if ($kProps[$pn].valueMap) {
                        foreach ($vk in $kProps[$pn].valueMap.Keys) { $p.ValueMap[[string]$vk] = [string]$kProps[$pn].valueMap[$vk] }
                    }
                    if ($kProps[$pn].range) {
                        $r = $kProps[$pn].range
                        $p.Range = [System.Tuple]::Create([int]$r[0], [int]$r[1])
                    }
                    $k.Properties[$pn] = $p
                }
                $script:FastHostKeywords[$kKeyword] = $k

                $MyTypeName = $kDriver.myTypeName
                $InstanceName = $kDriver.instanceName
                $PsDscRunAsCredential = $kDriver.psDscRunAsCredential
                $DependsOn = $kDriver.dependsOn
                $IsMetaConfig = [bool]$kDriver.isMetaConfig
                $V1MetaConfigPropertyList = $script:V1MetaConfigPropertyList
                $startErrors = $Script:PSConfigurationErrors
                $result = & (Get-CimKeywordImplementationFunction) -KeywordData $k -Name $kName -Value $kValue -SourceMetadata $kSource
                [PSCustomObject]@{
                    result     = $result
                    errorCount = $Script:PSConfigurationErrors - $startErrors
                }
            }

            $diag = & {
                try { Invoke-PSDscInEngineScope -ScriptBlock $sb -ArgumentList @($Keyword, $ResourceName, $NameMode, $ImplementingModule, $Props, $Value, $Name, $Driver, 'direct.ps1::1::1::Direct') }
                catch { $_ }
            } 2>&1

            $errors = @($diag | Where-Object -FilterScript { $_ -is [System.Management.Automation.ErrorRecord] })
            [PSCustomObject]@{
                Result      = $diag | Where-Object -FilterScript { $_ -isnot [System.Management.Automation.ErrorRecord] } | Select-Object -First 1
                Errors      = $errors
                Diagnostic  = (@($errors | ForEach-Object -Process { $_.ToString() }) -join [System.Environment]::NewLine)
            }
        }

        $script:PlainKeywordProps = @{
            Name            = @{ type = 'string'; mandatory = $false; isKey = $true; values = @(); valueMap = $null; range = $null }
            Value           = @{ type = 'string'; mandatory = $true; isKey = $false; values = @(); valueMap = $null; range = $null }
            DependsOn       = @{ type = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
            PsDscRunAsCredential = @{ type = 'string'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
        }
    }

    AfterAll {
        Reset-PSDscFastHostState
    }

    It 'rejects a value outside the property Range' {
        $props = $script:PlainKeywordProps.Clone()
        $props['Number'] = @{ type = 'int'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = @(1, 10) }
        $r = Invoke-PSDscCimDirect -Keyword 'DirectPlain' -ResourceName 'DirectPlainResource' -NameMode 'SimpleOptionalName' -ImplementingModule 'DirectModule' -Props $props `
            -Value @{ Name = 'x'; Value = 'v'; DependsOn = @('[DirectPlain]z'); Number = 15 } -Name 'x' -Driver @{ node = 'localhost'; isMetaConfig = $false }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 1
        $r.Diagnostic | Should -Match 'not between valid range'
    }

    It 'rejects V2-only properties in an old-style LocalConfigurationManager block' {
        $props = @{
            RefreshMode                = @{ type = 'string'; mandatory = $false; isKey = $false; values = @('Push', 'Pull', 'Disabled'); valueMap = $null; range = $null }
            StatusRetentionTimeInDays  = @{ type = 'string'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
        }
        $r = Invoke-PSDscCimDirect -Keyword 'LocalConfigurationManager' -ResourceName 'MSFT_DSCMetaConfiguration' -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ RefreshMode = 'Push'; StatusRetentionTimeInDays = 5 } -Name '' -Driver @{ node = 'localhost'; isMetaConfig = $false }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 1
        $r.Diagnostic | Should -Match 'StatusRetentionTimeInDays'
    }

    It 'qualifies nested DependsOn and resource ids in a composite context' {
        $r = Invoke-PSDscCimDirect -Keyword 'DirectComposite' -ResourceName 'DirectCompositeResource' -NameMode 'NameRequired' -ImplementingModule 'DirectModule' -Props $script:PlainKeywordProps `
            -Value @{ Name = 'x'; Value = 'v'; DependsOn = @('[DirectComposite]y') } -Name 'x' `
            -Driver @{ node = 'localhost'; isMetaConfig = $false; myTypeName = 'OuterComposite'; instanceName = 'outer'; dependsOn = @('outer'); nesting = @('root', 'inner') }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 0
        $nodeRes = Invoke-PSDscInEngineScope { $script:NodeResources['[DirectComposite]x::inner'] }
        $nodeRes | Should -BeExactly @('[DirectComposite]y::inner', 'outer')
    }

    It 'records the default meta configuration document on the unnamed node' {
        $r = Invoke-PSDscCimDirect -Keyword 'OMI_ConfigurationDocument' -ResourceName 'OMI_ConfigurationDocument' -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props @{} `
            -Value @{} -Name '' -Driver @{ node = $null; isMetaConfig = $true }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 0
        $default = Invoke-PSDscInEngineScope { $script:PSDefaultConfigurationDocument }
        $default | Should -Match 'instance of OMI_ConfigurationDocument'
    }

    It 'carries the meta version info into an already processed document instance' {
        $r = Invoke-PSDscCimDirect -Keyword 'OMI_ConfigurationDocument' -ResourceName 'OMI_ConfigurationDocument' -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props @{} `
            -Value @{} -Name '' -Driver @{ node = 'localhost'; isMetaConfig = $true; metaDocProcessed = $true }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 0
    }

    It 'sets the compatibility version on a non-meta configuration document' {
        $r = Invoke-PSDscCimDirect -Keyword 'OMI_ConfigurationDocument' -ResourceName 'OMI_ConfigurationDocument' -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props @{} `
            -Value @{} -Name '' -Driver @{ node = $null; isMetaConfig = $false }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 0
    }

    It 'reports a PsDscRunAsCredential merge and injects it when absent' {
        $merge = Invoke-PSDscCimDirect -Keyword 'DirectPlain' -ResourceName 'DirectPlainResource' -NameMode 'SimpleOptionalName' -ImplementingModule 'DirectModule' -Props $script:PlainKeywordProps `
            -Value @{ Name = 'x'; Value = 'v'; DependsOn = @('[DirectPlain]z'); PsDscRunAsCredential = 'inner' } -Name 'x' `
            -Driver @{ node = 'localhost'; isMetaConfig = $false; psDscRunAsCredential = 'outer' }
        $merge.Result | Should -Match 'ref'
        $merge.Errors.Count | Should -Be 1

        $inject = Invoke-PSDscCimDirect -Keyword 'DirectPlain' -ResourceName 'DirectPlainResource' -NameMode 'SimpleOptionalName' -ImplementingModule 'DirectModule' -Props $script:PlainKeywordProps `
            -Value @{ Name = 'x'; Value = 'v'; DependsOn = @('[DirectPlain]z') } -Name 'x' `
            -Driver @{ node = 'localhost'; isMetaConfig = $false; psDscRunAsCredential = 'outer' }
        $inject.Result | Should -Match 'ref'
        $inject.Errors.Count | Should -Be 0
    }

    It 'updates the meta version info for every configuration manager type' {
        foreach ($managerType in @('MSFT_WebDownloadManager', 'MSFT_FileDownloadManager', 'MSFT_WebResourceManager', 'MSFT_FileResourceManager', 'MSFT_WebReportManager', 'MSFT_SignatureValidation', 'MSFT_PartialConfiguration')) {
            $r = Invoke-PSDscCimDirect -Keyword 'DirectMetaManager' -ResourceName $managerType -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props @{} `
                -Value @{} -Name '' -Driver @{ node = $null; isMetaConfig = $true }
            $r.Result | Should -Match 'ref'
            $r.Errors.Count | Should -Be 0
        }
    }

    It 'rejects a DebugMode with more than one value' {
        $props = @{
            RefreshMode = @{ type = 'string'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
            DebugMode   = @{ type = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
        }
        $r = Invoke-PSDscCimDirect -Keyword 'LocalConfigurationManager' -ResourceName 'MSFT_DSCMetaConfiguration' -NameMode 'NoName' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ RefreshMode = 'Push'; DebugMode = @('ForceModuleImport', 'All') } -Name '' -Driver @{ node = 'localhost'; isMetaConfig = $false }

        $r.Result | Should -Match 'ref'
        $r.Errors.Count | Should -Be 1
        $r.Diagnostic | Should -Match 'DebugMode'
    }

    It 'processes every PartialConfiguration branch' {
        $props = @{
            Name                 = @{ type = 'string'; mandatory = $false; isKey = $true; values = @(); valueMap = $null; range = $null }
            RefreshMode          = @{ type = 'string'; mandatory = $false; isKey = $false; values = @('Push', 'Pull', 'Disabled'); valueMap = $null; range = $null }
            ConfigurationSource  = @{ type = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
            ResourceModuleSource = @{ type = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
            ExclusiveResources   = @{ type = 'string[]'; mandatory = $false; isKey = $false; values = @(); valueMap = $null; range = $null }
        }
        $base = @{ node = 'localhost'; isMetaConfig = $false }

        $pull = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Pull' } -Name 'p' -Driver $base
        $pull.Errors.Count | Should -Be 1
        $pull.Diagnostic | Should -Match 'Pull'

        $disabled = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Disabled' } -Name 'p' -Driver $base
        $disabled.Errors.Count | Should -Be 1

        $withSource = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Push'; ConfigurationSource = @('cfg1') } -Name 'p' -Driver $base
        $withSource.Errors.Count | Should -Be 0
        $withSource.Result | Should -Match 'ref'
        Invoke-PSDscInEngineScope { $script:NodeManager['[PartialConfiguration]p'] } | Should -BeExactly @('cfg1')

        $withModuleSource = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Push'; ResourceModuleSource = @('mod1') } -Name 'p' -Driver $base
        $withModuleSource.Errors.Count | Should -Be 0
        Invoke-PSDscInEngineScope { $script:NodeResourceSource['[PartialConfiguration]p'] } | Should -BeExactly @('mod1')

        $badExclusive = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Push'; ExclusiveResources = @('BadRef!') } -Name 'p' -Driver $base
        $badExclusive.Errors.Count | Should -Be 1

        $goodExclusive = Invoke-PSDscCimDirect -Keyword 'PartialConfiguration' -ResourceName 'MSFT_PartialConfiguration' -NameMode 'NameRequired' -ImplementingModule 'PSDesiredStateConfigurationEngine' -Props $props `
            -Value @{ Name = 'p'; RefreshMode = 'Push'; ExclusiveResources = @('mod\x') } -Name 'p' -Driver $base
        $goodExclusive.Errors.Count | Should -Be 0
        $goodExclusive.Result | Should -Match 'ref'
        Invoke-PSDscInEngineScope { $script:NodeExclusiveResources['[PartialConfiguration]p'] } | Should -BeExactly @('mod\x')
    }
}

Describe 'Coverage: psm1 engine internals via direct invocation' {
    BeforeAll {
        function New-ProbeProperty {
            param(
                [string] $Name,
                [string] $TypeConstraint = 'string',
                [bool] $IsKey = $false
            )
            $p = New-Object System.Management.Automation.Language.DynamicKeywordProperty
            $p.Name = $Name
            $p.TypeConstraint = $TypeConstraint
            $p.Mandatory = $false
            $p.IsKey = $IsKey
            $p
        }

        function New-ProbeKeyword {
            param(
                [string] $Name,
                [hashtable] $PropertyTypes
            )
            $k = New-Object System.Management.Automation.Language.DynamicKeyword
            $k.Keyword = $Name
            $k.ResourceName = $Name
            $k.NameMode = [System.Management.Automation.Language.DynamicKeywordNameMode]::SimpleOptionalName
            $k.BodyMode = [System.Management.Automation.Language.DynamicKeywordBodyMode]::ScriptBlock
            $k.ImplementingModule = 'ProbeModule'
            foreach ($pn in $PropertyTypes.Keys) {
                $k.Properties[$pn] = New-ProbeProperty -Name $pn -TypeConstraint $PropertyTypes[$pn]
            }
            $k
        }

        function New-ProbeMofHash {
            param([hashtable] $Entries)
            $d = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $Entries.Keys) {
                $d[$key] = [string]$Entries[$key]
            }
            $d
        }

        $script:ProbeOutRoot = Join-Path $env:TEMP 'opencode\probe-out'
        $null = New-Item -ItemType Directory -Path $script:ProbeOutRoot -Force

        $script:ProbeMetaText = "`ninstance of MSFT_DSCMetaConfigurationV2 as `$MSFT_DSCMetaConfiguration1ref `n{`n};`n"
        $script:ProbeMetaTextNoOmi = "`ninstance of MSFT_DSCMetaConfiguration as `$MSFT_DSCMetaConfiguration1ref `n{`n};`n"
        $script:ProbeOmiText = "`ninstance of OMI_ConfigurationDocument as `$OMI_ConfigurationDocument1ref `n{`nVersion = '1.0.0';`n};`n"
    }

    Describe 'ConvertTo-MOFInstance direct probes' {
        It 'rejects a null value for an embedded instance property' {
            $kw = New-ProbeKeyword -Name 'ProbeInst' -PropertyTypes @{ Inst = 'Instance'; SourceInfo = 'string' }

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    $script:FastHostKeywords = @{ 'ProbeInst' = $args[0] }
                    $script:IsMetaConfig = $false
                    ConvertTo-MOFInstance -Type 'ProbeInst' -Properties @{ Inst = $null; SourceInfo = 'probe.ps1:1:1' }
                } @($kw)
            }

            $diag | Should -Match 'Cannot convert'
        }

        It 'records domain credential usage from the AllNodes configuration data' {
            $kw = New-ProbeKeyword -Name 'ProbeCred' -PropertyTypes @{ PsDscRunAsCredential = 'Instance'; SourceInfo = 'string' }
            $credKw = New-ProbeKeyword -Name 'MSFT_Credential' -PropertyTypes @{ UserName = 'string'; Password = 'string' }
            $cred = [PSCredential]::new('CONTOSO\user', (ConvertTo-SecureString 'p@ss' -AsPlainText -Force))

            $usedDomain = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostKeywords = @{ 'ProbeCred' = $args[0]; 'MSFT_Credential' = $args[1] }
                $script:IsMetaConfig = $false
                $script:NodeUsingDomainCred = $null
                $Node = $null
                $selectedNodesData = $null
                $allnodes = @{ AllNodes = @( @{ NodeName = 'localhost'; PSDscAllowPlainTextPassword = $true } ) }
                $null = ConvertTo-MOFInstance -Type 'ProbeCred' -Properties @{ PsDscRunAsCredential = $args[2]; SourceInfo = 'probe.ps1:1:1' }
                $script:NodeUsingDomainCred['localhost']
            } @($kw, $credKw, $cred)

            $usedDomain | Should -Be $true
        }

        It 'initializes the node alias tables for the first instance of a node' {
            $kw = New-ProbeKeyword -Name 'ProbeNamed' -PropertyTypes @{ Value = 'string'; SourceInfo = 'string' }

            $aliasCount = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostKeywords = @{ 'ProbeNamed' = $args[0] }
                Set-PSCurrentConfigurationNode 'probeNode'
                $null = $script:NodeInstanceAliases.Remove('probeNode')
                $null = $script:NodeResourceIdAliases.Remove('probeNode')
                $null = ConvertTo-MOFInstance -Type 'ProbeNamed' -Properties @{}
                $count = $script:NodeInstanceAliases['probeNode'].Count
                Set-PSCurrentConfigurationNode ''
                $count
            } @($kw)

            $aliasCount | Should -Be 1
        }
    }

    Describe 'Test-ConflictingResources direct probes' {
        BeforeEach {
            $script:KeyDkp = New-ProbeProperty -Name 'K' -IsKey $true
            $script:PlainDkp = New-ProbeProperty -Name 'P'
        }

        It 'initializes the duplicate resource tracker' {
            $keywordData = @{ Properties = @{ K = $script:KeyDkp; P = $script:PlainDkp } }

            $null = & {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    $script:DuplicateResources = $null
                    Test-ConflictingResources -keyword 'ProbeConfInit' -properties @{ K = 'k1'; P = 'p1'; ResourceID = 'r1'; SourceInfo = 's1' } -keywordData $args[0]
                } @($keywordData)
            } 2>&1

            $state = Invoke-PSDscInEngineScope { $null -ne $script:DuplicateResources }
            $state | Should -Be $true
        }

        It 'flags two resources whose key properties differ in type' {
            $keywordData = @{ Properties = @{ K = $script:KeyDkp; P = $script:PlainDkp } }

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    Test-ConflictingResources -keyword 'ProbeConfKey' -properties @{ K = $null; P = 'x'; ResourceID = 'r1'; SourceInfo = 's1' } -keywordData $args[0]
                    Test-ConflictingResources -keyword 'ProbeConfKey' -properties @{ K = ''; P = 'x'; ResourceID = 'r2'; SourceInfo = 's2' } -keywordData $args[0]
                } @($keywordData)
            }

            $diag | Should -Not -Match 'A conflict was detected between resources'
        }

        It 'flags conflicting non-key property values when the current value is falsy' {
            $keywordData = @{ Properties = @{ K = $script:KeyDkp; P = $script:PlainDkp } }

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    Test-ConflictingResources -keyword 'ProbeConfNonKey' -properties @{ K = 'k1'; P = 'x'; ResourceID = 'r1'; SourceInfo = 's1' } -keywordData $args[0]
                    Test-ConflictingResources -keyword 'ProbeConfNonKey' -properties @{ K = 'k1'; P = $false; ResourceID = 'r2'; SourceInfo = 's2' } -keywordData $args[0]
                } @($keywordData)
            }

            $diag | Should -Match 'A conflict was detected between resources'
        }

        It 'flags a current-only falsy property as conflicting' {
            $keywordData = @{ Properties = @{ K = $script:KeyDkp; P = $script:PlainDkp } }

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    Test-ConflictingResources -keyword 'ProbeConfExtra' -properties @{ K = 'k1'; ResourceID = 'r1'; SourceInfo = 's1' } -keywordData $args[0]
                    Test-ConflictingResources -keyword 'ProbeConfExtra' -properties @{ K = 'k1'; P = $false; ResourceID = 'r2'; SourceInfo = 's2' } -keywordData $args[0]
                } @($keywordData)
            }

            $diag | Should -Match 'A conflict was detected between resources'
        }
    }

    Describe 'ValidateNoNameNodeResources direct probe' {
        It 'expands suffix matches and reports missing required resources' {
            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    $dict = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([System.StringComparer]::OrdinalIgnoreCase)
                    $dict['r1'] = [string[]]@('foo')
                    $dict['barfoo'] = [string[]]@()
                    $dict['r2'] = [string[]]@('zork')
                    $script:NoNameNodesResources = $dict
                    ValidateNoNameNodeResources
                    $script:NoNameNodesResources = $null
                }
            }

            $diag | Should -Match 'does not exist'
        }
    }

    Describe 'ValidateNoCircleInNodeResources direct probe' {
        It 'reports a dependency chain that exceeds the maximum component depth' {
            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    $chain = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([System.StringComparer]::OrdinalIgnoreCase)
                    for ($i = 0; $i -lt 1026; $i++) {
                        if ($i -lt 1025) {
                            $dep = "r$($i + 1)"
                            $chain["r$i"] = [string[]]@($dep)
                        } else {
                            $chain["r$i"] = [string[]]@()
                        }
                    }
                    $script:NodeResources = $chain
                    ValidateNoCircleInNodeResources
                    $script:NodeResources = $null
                }
            }

            $diag | Should -Match 'max depth'
        }
    }

    Describe 'Write-MetaConfigFile direct probes' {
        It 'captures the OMI configuration document and the local configuration manager' {
            $outDir = Join-Path $script:ProbeOutRoot 'meta-omi'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $hash = New-ProbeMofHash @{
                'OMI_ConfigurationDocument' = $script:ProbeOmiText
                'MSFT_DSCMetaConfiguration' = $script:ProbeMetaText
            }

            $null = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostActive = $true
                $script:FastHostValidateMof = $false
                $script:PSDefaultConfigurationDocument = $null
                $ConfigurationOutputDirectory = $args[0]
                Write-MetaConfigFile -ConfigurationName 'ProbeMeta' -mofNode 'localhost' -mofNodeHash $args[1]
            } @($outDir, $hash)

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof') | Should -Be $true
        }

        It 'adds the default local configuration manager and default document' {
            $outDir = Join-Path $script:ProbeOutRoot 'meta-default'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $hash = New-ProbeMofHash @{ 'SomeKey' = 'not a meta instance' }

            $null = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostActive = $true
                $script:FastHostValidateMof = $false
                $script:PSDefaultConfigurationDocument = $args[2]
                $ConfigurationOutputDirectory = $args[0]
                Write-MetaConfigFile -ConfigurationName 'ProbeMeta' -mofNode 'localhost' -mofNodeHash $args[1]
            } @($outDir, $hash, $script:ProbeOmiText)

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof') | Should -Be $true
        }

        It 'writes a .meta.mof.error file for invalid meta text' {
            $outDir = Join-Path $script:ProbeOutRoot 'meta-error'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $hash = New-ProbeMofHash @{
                'MSFT_DSCMetaConfiguration' = $script:ProbeMetaText
                'OMI_ConfigurationDocument' = 'garbage invalid mof'
            }

            $null = & {
                try {
                    Invoke-PSDscInEngineScope {
                        Initialize-ConfigurationRuntimeState
                        $script:FastHostActive = $false
                        $script:FastHostValidateMof = $false
                        $script:PSDefaultConfigurationDocument = $args[2]
                        $ConfigurationOutputDirectory = $args[0]
                        Write-MetaConfigFile -ConfigurationName 'ProbeMeta' -mofNode 'localhost' -mofNodeHash $args[1]
                    } @($outDir, $hash, $script:ProbeOmiText)
                } catch { $_ }
            } 2>&1

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof.error') | Should -Be $true
        }
    }

    Describe 'Write-NodeMOFFile direct probes' {
        It 'routes embedded instances to the meta document' {
            $outDir = Join-Path $script:ProbeOutRoot 'node-embedded'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $metaText = "`ninstance of MSFT_DSCMetaConfiguration as `$MSFT_DSCMetaConfiguration1ref `n{`nFooBar`n};`n"
            $hash = New-ProbeMofHash @{
                'MSFT_DSCMetaConfiguration' = $metaText
                'FooBar' = "`ninstance of FooBar as `$FooBar1ref `n{`nPsDscRunAsCredential = 'x'`n};`n"
                'PsDsc' = "`ninstance of PsDsc as `$PsDsc1ref `n{`nPsDscRunAsCredential = 'x'`n};`n"
            }

            $null = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostActive = $true
                $script:FastHostValidateMof = $false
                $script:PSDefaultConfigurationDocument = $null
                $ConfigurationOutputDirectory = $args[0]
                Write-NodeMOFFile -ConfigurationName 'ProbeNode' -mofNode 'localhost' -mofNodeHash $args[1]
            } @($outDir, $hash)

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof') | Should -Be $true
        }

        It 'captures the OMI document into the node meta document' {
            $outDir = Join-Path $script:ProbeOutRoot 'node-omi'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $hash = New-ProbeMofHash @{
                'MSFT_DSCMetaConfiguration' = $script:ProbeMetaTextNoOmi
                'OMI_ConfigurationDocument' = $script:ProbeOmiText
            }

            $null = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostActive = $true
                $script:FastHostValidateMof = $false
                $script:PSDefaultConfigurationDocument = $null
                $ConfigurationOutputDirectory = $args[0]
                Write-NodeMOFFile -ConfigurationName 'ProbeNode' -mofNode 'localhost' -mofNodeHash $args[1]
            } @($outDir, $hash)

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.mof') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof') | Should -Be $true
        }

        It 'appends the default configuration document when no OMI document is present' {
            $outDir = Join-Path $script:ProbeOutRoot 'node-default-doc'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $metaText = "`ninstance of MSFT_DSCMetaConfiguration as `$MSFT_DSCMetaConfiguration1ref `n{`nFooBar`n};`n"
            $hash = New-ProbeMofHash @{
                'MSFT_DSCMetaConfiguration' = $metaText
                'FooBar' = "`ninstance of FooBar as `$FooBar1ref `n{`n};`n"
                'BarBaz' = "`ninstance of BarBaz as `$BarBaz1ref `n{`n};`n"
            }

            $null = Invoke-PSDscInEngineScope {
                Initialize-ConfigurationRuntimeState
                $script:FastHostActive = $true
                $script:FastHostValidateMof = $false
                $script:PSDefaultConfigurationDocument = $args[2]
                $ConfigurationOutputDirectory = $args[0]
                Write-NodeMOFFile -ConfigurationName 'ProbeNode' -mofNode 'localhost' -mofNodeHash $args[1]
            } @($outDir, $hash, $script:ProbeOmiText)

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.mof') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $outDir 'localhost.meta.mof') | Should -Be $true
        }

        It 'writes a .mof.error file for invalid node text' {
            $outDir = Join-Path $script:ProbeOutRoot 'node-error'
            $null = New-Item -ItemType Directory -Path $outDir -Force
            $hash = New-ProbeMofHash @{ 'OMI_ConfigurationDocument' = 'garbage invalid mof' }

            $null = & {
                try {
                    Invoke-PSDscInEngineScope {
                        Initialize-ConfigurationRuntimeState
                        $script:FastHostActive = $false
                        $script:FastHostValidateMof = $false
                        $script:PSDefaultConfigurationDocument = $null
                        $ConfigurationOutputDirectory = $args[0]
                        Write-NodeMOFFile -ConfigurationName 'ProbeNode' -mofNode 'localhost' -mofNodeHash $args[1]
                    } @($outDir, $hash)
                } catch { $_ }
            } 2>&1

            Test-Path -LiteralPath (Join-Path $outDir 'localhost.mof.error') | Should -Be $true
        }
    }

    Describe 'ReadEnvironmentFile direct probe' {
        It 'counts an unresolvable data file path as an error' {
            $delta = @(& {
                try {
                    Invoke-PSDscInEngineScope {
                        function Resolve-Path { param($Path) throw 'forced resolve failure' }
                        $ErrorActionPreference = 'Continue'
                        $before = Get-ConfigurationErrorCount
                        ReadEnvironmentFile -FilePath 'Z:\missing\environment.psd1'
                        Remove-Item -LiteralPath function:Resolve-Path -ErrorAction SilentlyContinue
                        (Get-ConfigurationErrorCount) - $before
                    }
                } catch { $_ }
            } 2>&1 | Where-Object { $_ -is [int] })

            $delta | Should -BeGreaterThan 0
        }
    }

    Describe 'Get-InvokeDscResourceResult direct probe' {
        It 'reports a reboot when the resource sets DSCMachineStatus' {
            $result = Invoke-PSDscInEngineScope {
                $global:DSCMachineStatus = 1
                Get-InvokeDscResourceResult -Output @() -Method 'Set'
            }
            $global:DSCMachineStatus = 0
            $result.RebootRequired | Should -Be $true
        }
    }

    Describe 'Node direct invocation probes' {
        It 'initializes the duplicate resource tracker' {
            $functionsToDefine = New-Object 'System.Collections.Generic.Dictionary[string,ScriptBlock]' ([System.StringComparer]::OrdinalIgnoreCase)
            $emptyBody = { }

            $initialized = & {
                try {
                    Invoke-PSDscInEngineScope {
                        Initialize-ConfigurationRuntimeState
                        $functionsToDefine = $args[0]
                        $script:ConfigurationData = $null
                        $script:DuplicateResources = $null
                        $script:FastHostKeywords = @{}
                        Node -KeywordData @{} -Name @('probeNode') -Value $args[1] -sourceMetadata 'probe.ps1::1::1::Node'
                        $null -ne $script:DuplicateResources
                    } @($functionsToDefine, $emptyBody)
                } catch { $_ }
            } 2>&1

            $initialized | Should -Be $true
        }

        It 'reports an exception raised while processing a node' {
            $functionsToDefine = New-Object 'System.Collections.Generic.Dictionary[string,ScriptBlock]' ([System.StringComparer]::OrdinalIgnoreCase)

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscInEngineScope {
                    Initialize-ConfigurationRuntimeState
                    $functionsToDefine = $args[0]
                    $script:ConfigurationData = $null
                    $script:FastHostKeywords = @{}
                    $script:NodesInThisConfiguration = $null
                    Node -KeywordData @{} -Name @('probeNode') -Value { } -sourceMetadata 'probe.ps1::1::1::Node'
                } @($functionsToDefine)
            }

            $diag | Should -Match 'An exception was raised'
        }
    }

    Describe 'Configuration compile probes' {
        It 'reports a MethodInvocationException raised by the configuration body' {
            $text = @'
configuration ThrowTopLevelCfg
{
    $null = [System.Net.IPAddress]::Parse('bad')
    Import-DscResource -ModuleName xTestClassResource
}
'@

            $diag = Get-PSDscDiagnosticText {
                Invoke-PSDscConfigurationText -Text $text -Name ThrowTopLevelCfg -OutputPath (Join-Path $TestDrive 'throw-top-level')
            }

            $diag | Should -Match 'Parse'
        }

        It 'writes a node-less meta configuration document' {
            $text = @'
[DSCLocalConfigurationManager()]
configuration MetaNoNodeCfg
{
    Settings
    {
        RefreshMode = 'Push'
    }
}
'@

            $outputPath = Join-Path $TestDrive 'meta-no-node'
            $result = Get-PSDscDiagnosticText {
                Invoke-PSDscConfigurationText -Text $text -Name MetaNoNodeCfg -OutputPath $outputPath
            }

            $result | Should -Be ''
            Test-Path -LiteralPath (Join-Path $outputPath 'localhost.meta.mof') | Should -Be $true
        }

        It 'honours -WarningAction when built-in resources are used without an import' {
            $text = @'
configuration BuiltinWarnArgCfg
{
    Node localhost
    {
        Log l
        {
            Message = 'hello built-in log'
        }
    }
}
'@
            Invoke-Expression -Command $text

            $warnings = & {
                BuiltinWarnArgCfg -OutputPath (Join-Path $TestDrive 'builtin-warn-arg') -WarningAction SilentlyContinue
            } 3>&1

            (@($warnings) -join ' ') | Should -Not -Match 'built-in resources without explicitly importing'
        }

        It 'honours -WarningAction when a domain credential is used' {
            $text = @'
configuration DomainWarnArgCfg
{
    param
    (
        [PSCredential]
        $Credential
    )

    Import-DscResource -ModuleName xTestCredentialResource
    Node localhost
    {
        xTestCredentialResource a
        {
            Name = 'secret-holder'
            Credential = $Credential
        }
    }
}
'@
            Invoke-Expression -Command $text

            $credential = [PSCredential]::new('CONTOSO\user', (ConvertTo-SecureString 'Pl41nT3xtP@ss' -AsPlainText -Force))

            $warnings = & {
                DomainWarnArgCfg -Credential $credential `
                    -OutputPath (Join-Path $TestDrive 'domain-warn-arg') `
                    -ConfigurationData @{ AllNodes = @(@{ NodeName = 'localhost'; PSDscAllowPlainTextPassword = $true }) } `
                    -WarningAction SilentlyContinue
            } 3>&1

            (@($warnings) -join ' ') | Should -Not -Match 'not recommended to use domain credential'
        }

        It 'reports an output path that cannot be created as a directory' {
            $text = @'
configuration BadMkdirCfg
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
            Invoke-Expression -Command $text

            $diag = Get-PSDscDiagnosticText {
                BadMkdirCfg -OutputPath (Join-Path $TestDrive 'bad<name>')
            }

            $diag | Should -Match 'valid path segment'
        }
    }
}