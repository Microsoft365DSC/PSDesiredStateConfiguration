BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine
}

AfterAll {
    Restore-PSDscTestModulePath
}

Describe 'New-DscChecksum' {
    BeforeEach {
        $script:SourceDirectory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:SourceDirectory
        $script:MofPath = Join-Path $script:SourceDirectory 'localhost.mof'
        [System.IO.File]::WriteAllText($script:MofPath, 'instance of OMI_ConfigurationDocument{};')
        $script:ZipPath = Join-Path $script:SourceDirectory 'payload.zip'
        [System.IO.File]::WriteAllBytes($script:ZipPath, [byte[]] @(0x50, 0x4B, 0x05, 0x06))
        $script:IgnoredPath = Join-Path $script:SourceDirectory 'notes.txt'
        [System.IO.File]::WriteAllText($script:IgnoredPath, 'ignored')
    }

    It 'writes a checksum next to every mof and zip file' {
        New-DscChecksum -Path $script:SourceDirectory

        "$($script:MofPath).checksum" | Should -Exist
        "$($script:ZipPath).checksum" | Should -Exist
        "$($script:IgnoredPath).checksum" | Should -Not -Exist
    }

    It 'writes the SHA256 hash of the file without a trailing newline' {
        New-DscChecksum -Path $script:SourceDirectory

        $expected = (Get-FileHash -Path $script:MofPath -Algorithm SHA256).Hash
        [System.IO.File]::ReadAllText("$($script:MofPath).checksum") | Should -BeExactly $expected
    }

    It 'accepts the ConfigurationPath alias' {
        New-DscChecksum -ConfigurationPath $script:SourceDirectory

        "$($script:MofPath).checksum" | Should -Exist
    }

    It 'accepts several paths at once' {
        $secondDirectory = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $secondDirectory
        $secondMof = Join-Path $secondDirectory 'second.mof'
        [System.IO.File]::WriteAllText($secondMof, 'instance of OMI_ConfigurationDocument{};')

        New-DscChecksum -Path @($script:SourceDirectory, $secondDirectory)

        "$($script:MofPath).checksum" | Should -Exist
        "$secondMof.checksum" | Should -Exist
    }

    It 'keeps an existing checksum without -Force' {
        $checksumPath = "$($script:MofPath).checksum"
        [System.IO.File]::WriteAllText($checksumPath, 'STALE')

        New-DscChecksum -Path $script:SourceDirectory

        [System.IO.File]::ReadAllText($checksumPath) | Should -BeExactly 'STALE'
    }

    It 'overwrites an existing checksum with -Force' {
        $checksumPath = "$($script:MofPath).checksum"
        [System.IO.File]::WriteAllText($checksumPath, 'STALE')

        New-DscChecksum -Path $script:SourceDirectory -Force

        [System.IO.File]::ReadAllText($checksumPath) | Should -BeExactly (Get-FileHash -Path $script:MofPath -Algorithm SHA256).Hash
    }

    It 'writes into -OutPath and creates that directory' {
        $outPath = Join-Path $TestDrive 'checksums-created'

        New-DscChecksum -Path $script:SourceDirectory -OutPath $outPath

        Join-Path $outPath 'localhost.mof.checksum' | Should -Exist
        Join-Path $outPath 'payload.zip.checksum' | Should -Exist
        "$($script:MofPath).checksum" | Should -Not -Exist
    }

    It 'writes nothing with -WhatIf' {
        New-DscChecksum -Path $script:SourceDirectory -WhatIf

        "$($script:MofPath).checksum" | Should -Not -Exist
    }

    It 'reports that no configuration file was found for an empty directory' {
        $emptyDirectory = Join-Path $TestDrive 'empty-source'
        $null = New-Item -ItemType Directory -Path $emptyDirectory

        $messages = New-DscChecksum -Path $emptyDirectory -Verbose 4>&1

        ($messages -join ' ') | Should -Match 'No valid config files'
        @(Get-ChildItem -Path $emptyDirectory).Count | Should -Be 0
    }

    It 'throws for a path that does not exist' {
        { New-DscChecksum -Path (Join-Path $TestDrive 'no-such-directory') } |
            Should -Throw -ExpectedMessage '*Invalid configuration path*'
    }

    It 'throws for an -OutPath containing an invalid path character' {
        { New-DscChecksum -Path $script:SourceDirectory -OutPath "$TestDrive`0invalid" } |
            Should -Throw -ExpectedMessage '*Invalid OutPath*'
    }

    It 'throws when -OutPath is an existing file' {
        $filePath = Join-Path $TestDrive 'conflicting-outpath'
        [System.IO.File]::WriteAllText($filePath, 'occupied')

        { New-DscChecksum -Path $script:SourceDirectory -OutPath $filePath } |
            Should -Throw -ExpectedMessage '*A file exists with the same name*'
    }
}
