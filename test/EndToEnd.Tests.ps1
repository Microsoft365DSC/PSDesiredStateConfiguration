BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    $script:OriginalProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
}

AfterAll {
    $global:ProgressPreference = $script:OriginalProgressPreference
    Restore-PSDscTestModulePath
}

Describe 'Author, compile and publish a configuration' {
    BeforeAll {
        $script:WorkRoot = Join-Path $TestDrive 'e2e-author'
        $script:OutputPath = Join-Path $script:WorkRoot 'ManagedFilesCfg'
        $script:ManagedFile = Join-Path $script:WorkRoot 'managed.txt'
        $null = New-Item -ItemType Directory -Path $script:WorkRoot -Force

        $script:ScriptPath = Join-Path $script:WorkRoot 'ManagedFiles.ps1'
        $script:ScriptText = @"
Configuration ManagedFilesCfg
{
    Import-DscResource -ModuleName xTestStateResource

    Node localhost
    {
        xTestStateResource managed
        {
            Path = '$($script:ManagedFile.Replace('\', '\\'))'
            Content = 'end to end'
            Ensure = 'Present'
        }
    }
}

ManagedFilesCfg -OutputPath '$($script:OutputPath.Replace('\', '\\'))'
"@
        Set-Content -Path $script:ScriptPath -Value $script:ScriptText -Encoding Ascii

        $script:CompiledFiles = @(& $script:ScriptPath)
    }

    It 'writes one MOF per node' {
        @($script:CompiledFiles).Count | Should -Be 1
        $script:CompiledFiles[0].Name | Should -Be 'localhost.mof'
        $script:CompiledFiles[0].DirectoryName | Should -Be $script:OutputPath
    }

    It 'describes the resource and the document in the MOF' {
        $mof = Get-Content -Raw -Path $script:CompiledFiles[0].FullName

        $mof | Should -Match 'instance of xTestStateResource as \$xTestStateResource1ref'
        $mof | Should -Match 'ResourceID = "\[xTestStateResource\]managed"'
        $mof | Should -Match 'Content = "end to end"'
        $mof | Should -Match 'Ensure = "Present"'
        $mof | Should -Match 'ModuleName = "xTestStateResource"'
        $mof | Should -Match 'instance of OMI_ConfigurationDocument'
        $mof | Should -Match 'Name="ManagedFilesCfg"'
    }

    It 'publishes a checksum that matches the MOF' {
        New-DscChecksum -Path $script:OutputPath

        $checksumPath = "$($script:CompiledFiles[0].FullName).checksum"
        $checksumPath | Should -Exist
        [System.IO.File]::ReadAllText($checksumPath) |
            Should -BeExactly (Get-FileHash -Path $script:CompiledFiles[0].FullName -Algorithm SHA256).Hash
    }

    It 'recompiles to the same document after the checksum was published' {
        $recompiled = @(& $script:ScriptPath)

        Get-PSDscComparableMofLine -Path $recompiled[0].FullName |
            Should -Be (Get-PSDscComparableMofLine -Path $script:CompiledFiles[0].FullName)
    }
}

Describe 'Compile the same script through the fast host' {
    BeforeAll {
        $script:FastWorkRoot = Join-Path $TestDrive 'e2e-fast'
        $null = New-Item -ItemType Directory -Path $script:FastWorkRoot -Force
        $script:FastManagedFile = Join-Path $script:FastWorkRoot 'managed.txt'

        $script:FastScriptText = @"
Configuration FastManagedFilesCfg
{
    Import-DscResource -ModuleName xTestStateResource

    Node localhost
    {
        xTestStateResource managed
        {
            Path = '$($script:FastManagedFile.Replace('\', '\\'))'
            Content = 'end to end'
            Ensure = 'Present'
        }
    }
}
"@
        $script:SchemaCachePath = Join-Path $script:FastWorkRoot 'xTestStateResource.json'
        $null = Export-DscSchemaCache -ModuleName xTestStateResource -OutputPath $script:SchemaCachePath

        $script:StandardOutput = Join-Path $script:FastWorkRoot 'standard'
        $script:FastOutput = Join-Path $script:FastWorkRoot 'fast'
        $script:StandardMof = Invoke-PSDscConfigurationText -Text $script:FastScriptText -Name FastManagedFilesCfg -OutputPath $script:StandardOutput
        $script:FastMof = Invoke-DscFastCompile -ScriptText $script:FastScriptText -SchemaCachePath $script:SchemaCachePath -OutputPath $script:FastOutput -NoFallback
    }

    It 'produces a MOF without touching the standard compilation path' {
        $script:FastMof.Exists | Should -Be $true
        $script:FastMof.Name | Should -Be 'localhost.mof'
    }

    It 'produces the same document as the standard path' {
        $difference = Compare-Object `
            -ReferenceObject @(Get-PSDscComparableMofLine -Path $script:StandardMof.FullName) `
            -DifferenceObject @(Get-PSDscComparableMofLine -Path $script:FastMof.FullName)

        @($difference).Count | Should -Be 0
    }

    It 'leaves the schema cache valid for the module it was generated from' {
        $modulePath = (Get-Module -ListAvailable -Name xTestStateResource | Select-Object -First 1).ModuleBase

        Test-DscSchemaCache -ModulePath $modulePath -CachePath $script:SchemaCachePath -Detailed | Should -Be $true
    }
}

Describe 'Bring a resource into the desired state' {
    BeforeAll {
        $script:StateRoot = Join-Path $TestDrive 'e2e-state'
        $null = New-Item -ItemType Directory -Path $script:StateRoot -Force
        $script:StateFile = Join-Path $script:StateRoot 'state.txt'
        $script:PresentProperty = @{ Path = $script:StateFile; Content = 'desired'; Ensure = 'Present' }
    }

    It 'reports that the resource is not in the desired state yet' {
        $result = Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Test -Property $script:PresentProperty

        $result.InDesiredState | Should -BeFalse
    }

    It 'reads the current state before anything was applied' {
        $result = Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Get -Property $script:PresentProperty

        $result.GetType().Name | Should -Be 'xTestStateResource'
        $result.Ensure | Should -Be 'Absent'
        $result.Content | Should -BeExactly ''
    }

    It 'applies the desired state' {
        $result = Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Set -Property $script:PresentProperty

        $result.RebootRequired | Should -BeFalse
        $script:StateFile | Should -Exist
        [System.IO.File]::ReadAllText($script:StateFile) | Should -BeExactly 'desired'
    }

    It 'reports the desired state after applying it' {
        (Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Test -Property $script:PresentProperty).InDesiredState |
            Should -BeTrue
    }

    It 'reads back the applied state' {
        $result = Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Get -Property $script:PresentProperty

        $result.Ensure | Should -Be 'Present'
        $result.Content | Should -BeExactly 'desired'
    }

    It 'removes the resource again' {
        $absentProperty = @{ Path = $script:StateFile; Content = 'desired'; Ensure = 'Absent' }

        $null = Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Set -Property $absentProperty

        $script:StateFile | Should -Not -Exist
        (Invoke-DscResource -Name xTestStateResource -ModuleName xTestStateResource -Method Test -Property $absentProperty).InDesiredState |
            Should -BeTrue
    }
}

Describe 'Compile a multi node configuration end to end' {
    BeforeAll {
        $script:MultiRoot = Join-Path $TestDrive 'e2e-multinode'
        $null = New-Item -ItemType Directory -Path $script:MultiRoot -Force

        $text = @"
Configuration MultiNodeManagedFilesCfg
{
    Import-DscResource -ModuleName xTestStateResource

    Node `$AllNodes.NodeName
    {
        xTestStateResource managed
        {
            Path = Join-Path '$($script:MultiRoot.Replace('\', '\\'))' "`$(`$Node.NodeName).txt"
            Content = `$Node.Payload
            Ensure = 'Present'
        }
    }
}
"@
        $script:MultiOutput = Join-Path $script:MultiRoot 'out'
        $script:MultiFiles = @(Invoke-PSDscConfigurationText -Text $text -Name MultiNodeManagedFilesCfg -OutputPath $script:MultiOutput -ConfigurationData @{
                AllNodes = @(
                    @{ NodeName = '*'; Ensure = 'Present' }
                    @{ NodeName = 'NodeA'; Payload = 'payload-a' }
                    @{ NodeName = 'NodeB'; Payload = 'payload-b' }
                )
            })
    }

    It 'writes one MOF per node' {
        (($script:MultiFiles | ForEach-Object { $_.Name }) | Sort-Object) -join ',' | Should -Be 'NodeA.mof,NodeB.mof'
    }

    It 'resolves the node specific payload in every MOF' {
        foreach ($mof in $script:MultiFiles)
        {
            $nodeName = [System.IO.Path]::GetFileNameWithoutExtension($mof.Name)
            $content = Get-Content -Raw -Path $mof.FullName
            $content | Should -Match ('Content = "payload-' + $nodeName.Substring($nodeName.Length - 1).ToLowerInvariant() + '"')
            $content | Should -Match ([regex]::Escape("$nodeName.txt"))
        }
    }

    It 'publishes a checksum for every node MOF' {
        $checksumRoot = Join-Path $script:MultiRoot 'checksums'

        New-DscChecksum -Path $script:MultiOutput -OutPath $checksumRoot

        foreach ($mof in $script:MultiFiles)
        {
            $checksumPath = Join-Path $checksumRoot "$($mof.Name).checksum"
            $checksumPath | Should -Exist
            [System.IO.File]::ReadAllText($checksumPath) |
                Should -BeExactly (Get-FileHash -Path $mof.FullName -Algorithm SHA256).Hash
        }
    }
}
