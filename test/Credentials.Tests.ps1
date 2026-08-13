BeforeDiscovery {
    $script:CanIssueCertificate = [bool](Get-Command -Name 'New-SelfSignedCertificate' -ErrorAction Ignore)
}

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    $script:CredentialConfigurationText = @'
configuration CredentialCfg
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

    function New-PSDscTestCredential
    {
        param ([string] $UserName)

        [PSCredential]::new($UserName, (ConvertTo-SecureString -String 'Pl41nT3xtP@ss' -AsPlainText -Force))
    }

    function Invoke-PSDscCredentialConfiguration
    {
        [CmdletBinding()]
        param
        (
            [string] $UserName,
            [string] $OutputPath,
            [hashtable] $NodeData = @{}
        )

        $nodeEntry = @{ NodeName = 'localhost' } + $NodeData
        Invoke-Expression -Command $script:CredentialConfigurationText
        CredentialCfg -Credential (New-PSDscTestCredential -UserName $UserName) `
            -OutputPath $OutputPath -ConfigurationData @{ AllNodes = @($nodeEntry) }
    }

    $script:PublicKeyPath = Join-Path $TestDrive 'dsc-public-key.cer'
    $script:EncryptionCertificate = New-PSDscDocumentEncryptionCertificate -PublicKeyPath $script:PublicKeyPath
}

AfterAll {
    if ($script:EncryptionCertificate)
    {
        Remove-Item -Path $script:EncryptionCertificate.StorePath -Force -ErrorAction Ignore
    }

    Restore-PSDscTestModulePath
}

Describe 'IsDomainUser' {
    It 'classifies <UserName> as domain user <Expected>' -TestCases @(
        @{ UserName = 'localuser'; Expected = $false }
        @{ UserName = 'localhost\localuser'; Expected = $false }
        @{ UserName = '127.0.0.1\localuser'; Expected = $false }
        @{ UserName = 'CONTOSO\user'; Expected = $true }
        @{ UserName = 'user@contoso.com'; Expected = $true }
    ) {
        Invoke-PSDscInEngineScope { IsDomainUser -UserName $args[0] } $UserName | Should -Be $Expected
    }
}

Describe 'Plain text credentials' {
    It 'refuses to store a credential when neither a certificate nor PSDscAllowPlainTextPassword is set' {
        $diagnostics = Get-PSDscDiagnosticText {
            Invoke-PSDscCredentialConfiguration -UserName 'localuser' -OutputPath (Join-Path $TestDrive 'plain-refused')
        }

        $diagnostics | Should -Match 'storing encrypted passwords as plain text is not recommended'
        Join-Path $TestDrive 'plain-refused\localhost.mof' | Should -Not -Exist
    }

    It 'refuses to store a credential when the node has no configuration data at all' {
        Invoke-Expression -Command $script:CredentialConfigurationText

        $diagnostics = Get-PSDscDiagnosticText {
            CredentialCfg -Credential (New-PSDscTestCredential -UserName 'localuser') -OutputPath (Join-Path $TestDrive 'plain-nodata')
        }

        $diagnostics | Should -Match 'storing encrypted passwords as plain text is not recommended'
    }

    It 'writes an MSFT_Credential instance when PSDscAllowPlainTextPassword is set' {
        $result = Invoke-PSDscCredentialConfiguration -UserName 'localuser' `
            -OutputPath (Join-Path $TestDrive 'plain-allowed') -NodeData @{ PSDscAllowPlainTextPassword = $true }

        $content = Get-Content -Raw -Path $result.FullName
        $content | Should -Match 'instance of MSFT_Credential'
        $content | Should -Match 'UserName = "localuser"'
        $content | Should -Match 'Password = "Pl41nT3xtP@ss"'
        $content | Should -Not -Match 'ContentType="PasswordEncrypted"'
    }

    It 'warns about a domain credential' {
        $emitted = & {
            Invoke-PSDscCredentialConfiguration -UserName 'CONTOSO\user' `
                -OutputPath (Join-Path $TestDrive 'domain-warned') `
                -NodeData @{ PSDscAllowPlainTextPassword = $true }
        } 3>&1

        (@($emitted) -join ' ') | Should -Match 'not recommended to use domain credential'
    }

    It 'stays silent about a domain credential when PSDscAllowDomainUser is set' {
        $emitted = & {
            Invoke-PSDscCredentialConfiguration -UserName 'CONTOSO\user' `
                -OutputPath (Join-Path $TestDrive 'domain-allowed') `
                -NodeData @{ PSDscAllowPlainTextPassword = $true; PSDscAllowDomainUser = $true }
        } 3>&1

        (@($emitted) -join ' ') | Should -Not -Match 'not recommended to use domain credential'
        Get-Content -Raw -Path (Join-Path $TestDrive 'domain-allowed\localhost.mof') | Should -Match 'UserName = "CONTOSO\\\\user"'
    }
}

Describe 'Certificate protected credentials' {
    It 'encrypts the password with the certificate file and marks the document' -Skip:(-not $script:CanIssueCertificate) {
        $result = Invoke-PSDscCredentialConfiguration -UserName 'localuser' `
            -OutputPath (Join-Path $TestDrive 'cert-file') `
            -NodeData @{ CertificateFile = $script:PublicKeyPath }

        $content = Get-Content -Raw -Path $result.FullName
        $content | Should -Match 'BEGIN CMS'
        $content | Should -Not -Match 'Pl41nT3xtP@ss'
        $content | Should -Match 'ContentType="PasswordEncrypted"'
    }

    It 'encrypts the password with a certificate thumbprint' -Skip:(-not $script:CanIssueCertificate) {
        $result = Invoke-PSDscCredentialConfiguration -UserName 'localuser' `
            -OutputPath (Join-Path $TestDrive 'cert-thumbprint') `
            -NodeData @{ CertificateID = $script:EncryptionCertificate.Thumbprint }

        $content = Get-Content -Raw -Path $result.FullName
        $content | Should -Match 'BEGIN CMS'
        $content | Should -Not -Match 'Pl41nT3xtP@ss'
    }

    It 'reads a public key from a certificate file' -Skip:(-not $script:CanIssueCertificate) {
        $certificate = Invoke-PSDscInEngineScope { Get-PublicKeyFromFile -certificatefile $args[0] } $script:PublicKeyPath

        $certificate.Thumbprint | Should -Be $script:EncryptionCertificate.Thumbprint
    }

    It 'throws for a certificate file that cannot be read' {
        { Invoke-PSDscInEngineScope { Get-PublicKeyFromFile -certificatefile $args[0] } (Join-Path $TestDrive 'not-a-certificate.cer') } |
            Should -Throw -ExpectedMessage '*Error Reading certificate file*'
    }

    It 'throws for a thumbprint that is not in the machine store' {
        { Invoke-PSDscInEngineScope { Get-PublicKeyFromStore -certificateid $args[0] } '0000000000000000000000000000000000000000' } |
            Should -Throw -ExpectedMessage '*Error Reading certificate store*'
    }
}

Describe 'PsDscRunAsCredential' {
    It 'raises the minimum compatible version of the document to 2.0.0' {
        $text = @'
configuration RunAsCredentialCfg
{
    param
    (
        [PSCredential]
        $Credential
    )

    Import-DscResource -ModuleName xTestClassResource
    Node localhost
    {
        ResourceForTests1 a
        {
            Prop1 = 'x'
            PsDscRunAsCredential = $Credential
        }
    }
}
'@
        Invoke-Expression -Command $text
        $result = RunAsCredentialCfg -Credential (New-PSDscTestCredential -UserName 'localuser') `
            -OutputPath (Join-Path $TestDrive 'runas-credential') `
            -ConfigurationData @{ AllNodes = @(@{ NodeName = 'localhost'; PSDscAllowPlainTextPassword = $true }) }

        $content = Get-Content -Raw -Path $result.FullName
        $content | Should -Match 'PsDscRunAsCredential'
        $content | Should -Match 'MinimumCompatibleVersion = "2.0.0"'
    }

    It 'is rejected by Invoke-DscResource' {
        { Invoke-DscResource -Name ResourceForTests1 -ModuleName xTestClassResource -Method Test `
                -Property @{ Prop1 = 'x'; PsDscRunAsCredential = (New-PSDscTestCredential -UserName 'localuser') } } |
            Should -Throw -ExpectedMessage "*'PsDscRunAsCredential' property is not currently support*"
    }
}
