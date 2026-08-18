<#
.SYNOPSIS
    Shared helpers for the M365DSC.PSDesiredStateConfiguration Pester suites.
#>

$script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$script:EngineManifest = Join-Path -Path $script:RepositoryRoot -ChildPath 'M365DSC.PSDesiredStateConfiguration\M365DSC.PSDesiredStateConfiguration.psd1'
$script:OriginalPSModulePath = $null

<#
.SYNOPSIS
    Returns the root of the repository under test.
#>
function Get-PSDscRepositoryRoot
{
    [OutputType([System.String])]
    param ()

    $script:RepositoryRoot
}

<#
.SYNOPSIS
    Returns the manifest path of the engine module under test.
#>
function Get-PSDscEngineManifest
{
    [OutputType([System.String])]
    param ()

    $script:EngineManifest
}

<#
.SYNOPSIS
    Puts the bundled test resource modules and the compatibility module on PSModulePath.

.DESCRIPTION
    Compiled configurations resolve resource modules by name through PSModulePath, so the
    test modules have to be reachable before a configuration is parsed. The previous value
    is remembered so Restore-PSDscTestModulePath can put it back.
#>
function Add-PSDscTestModulePath
{
    [OutputType([void])]
    param ()

    if ($null -eq $script:OriginalPSModulePath)
    {
        $script:OriginalPSModulePath = $env:PSModulePath
    }

    $separator = [System.IO.Path]::PathSeparator
    $compatibilityRoot = Join-Path -Path (Split-Path -Path $script:EngineManifest -Parent) -ChildPath 'Compat'
    $env:PSModulePath = (Join-Path -Path $PSScriptRoot -ChildPath 'TestModules') +
        $separator + $compatibilityRoot +
        $separator + $env:PSModulePath
}

<#
.SYNOPSIS
    Restores the PSModulePath value Add-PSDscTestModulePath replaced.
#>
function Restore-PSDscTestModulePath
{
    [OutputType([void])]
    param ()

    if ($script:OriginalPSModulePath)
    {
        $env:PSModulePath = $script:OriginalPSModulePath
        $script:OriginalPSModulePath = $null
    }
}

<#
.SYNOPSIS
    Makes sure the engine module under test is loaded and starts from clean fast host state.

.DESCRIPTION
    The engine is imported once per process and globally. Reloading it per suite would leave
    the shipped compatibility module forwarding an engine instance that is no longer the one
    Get-Module reports, and the suites would then run against two different keyword caches.
    Compilation state resets itself per configuration; the fast host registration cache does
    not, so it is cleared here instead.
#>
function Import-PSDscEngine
{
    [OutputType([void])]
    param ()

    if (-not (Get-Module -Name M365DSC.PSDesiredStateConfiguration))
    {
        Import-Module -Name $script:EngineManifest -Force -Global
    }

    Reset-PSDscFastHostState
}

<#
.SYNOPSIS
    Copies a bundled test resource module to its own location under a version of its own.

.DESCRIPTION
    The fast host remembers which module versions it already registered keywords for, keyed by
    module name, and it looks a schema cache up in the module folder and in a per user folder
    whose name carries the module version. A suite that needs to observe that lookup has to work
    with a module version no other suite can have populated, otherwise it silently reuses what an
    earlier suite left behind. The returned object carries everything needed to put the copy on
    PSModulePath and to clean the generated cache up again.

.PARAMETER Name
    Name of the module under test/TestModules to copy.

.PARAMETER Version
    Version to stamp the copied manifest with. Must be unique across the suites.

.PARAMETER Destination
    Directory to copy the module folder into. It becomes the PSModulePath entry.
#>
function New-PSDscIsolatedTestModule
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Name,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Version,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Destination
    )

    $null = New-Item -ItemType Directory -Path $Destination -Force
    Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath "TestModules\$Name") -Destination $Destination -Recurse -Force

    $manifestPath = Join-Path -Path $Destination -ChildPath "$Name\$Name.psd1"
    $manifest = [System.IO.File]::ReadAllText($manifestPath) -replace "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion = '$Version'"
    [System.IO.File]::WriteAllText($manifestPath, $manifest)

    $module = Get-Module -ListAvailable -Name $manifestPath
    $userCachePath = Invoke-PSDscInEngineScope {
        Get-DscSchemaCacheUserPath -ModuleName $args[0].Name -ModuleVersion $args[0].Version `
            -Fingerprint (Get-DscModuleFingerprint -Module $args[0])
    } @($module)

    [PSCustomObject]@{
        Name          = $Name
        Root          = $Destination
        ManifestPath  = $manifestPath
        Module        = $module
        UserCachePath = $userCachePath
    }
}

<#
.SYNOPSIS
    Clears the fast host keyword registration the previous compilations left in the engine.
#>
function Reset-PSDscFastHostState
{
    [OutputType([void])]
    param ()

    Invoke-PSDscInEngineScope {
        $script:FastHostRegisteredModules = @{}
        $script:FastHostKeywords = $null
        $script:FastHostAdapters = $null
    }
}

<#
.SYNOPSIS
    Runs a script block inside the engine module scope so internal functions are reachable.

.PARAMETER ScriptBlock
    The script block to run. Arguments are passed through as $args.

.PARAMETER ArgumentList
    Arguments forwarded to the script block.
#>
function Invoke-PSDscInEngineScope
{
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.Management.Automation.ScriptBlock]
        $ScriptBlock,

        [Parameter(Position = 1)]
        [System.Object[]]
        $ArgumentList
    )

    $engine = Get-Module -Name M365DSC.PSDesiredStateConfiguration
    & $engine $ScriptBlock @ArgumentList
}

<#
.SYNOPSIS
    Compiles a configuration from text and returns the files it produced.

.PARAMETER Text
    The configuration script text. It must define exactly one configuration.

.PARAMETER Name
    The configuration name to invoke.

.PARAMETER OutputPath
    Provider path to write the MOF files to.

.PARAMETER ConfigurationData
    Optional configuration data passed to the configuration.
#>
function Invoke-PSDscConfigurationText
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Text,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Name,

        [Parameter(Mandatory = $true)]
        [System.String]
        $OutputPath,

        [Parameter()]
        [System.Collections.Hashtable]
        $ConfigurationData
    )

    Invoke-Expression -Command $Text

    $arguments = @{ OutputPath = $OutputPath }
    if ($ConfigurationData)
    {
        $arguments['ConfigurationData'] = $ConfigurationData
    }

    & $Name @arguments
}

<#
.SYNOPSIS
    Runs a script block and returns everything it wrote to the error stream, plus the
    message of a terminating error, as a single string.

.PARAMETER ScriptBlock
    The script block to run.
#>
function Get-PSDscDiagnosticText
{
    [OutputType([System.String])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.Management.Automation.ScriptBlock]
        $ScriptBlock
    )

    $messages = & {
        try
        {
            $null = & $ScriptBlock
        }
        catch
        {
            $_
        }
    } 2>&1

    (@($messages) | ForEach-Object -Process { $_.ToString() }) -join [System.Environment]::NewLine
}

<#
.SYNOPSIS
    Compiles a configuration and returns every diagnostic it produced as a single string.

.DESCRIPTION
    A failing compilation writes one error record per problem and finally throws. Both end
    up in the returned text, so a test can assert on the diagnostic it expects without
    caring which of the two channels carried it.

.PARAMETER Text
    The configuration script text. It must define exactly one configuration.

.PARAMETER Name
    The configuration name to invoke.

.PARAMETER OutputPath
    Provider path to write the MOF files to.

.PARAMETER ConfigurationData
    Optional configuration data passed to the configuration.
#>
function Get-PSDscCompilationDiagnostic
{
    [OutputType([System.String])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Text,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Name,

        [Parameter(Mandatory = $true)]
        [System.String]
        $OutputPath,

        [Parameter()]
        [System.Collections.Hashtable]
        $ConfigurationData
    )

    Invoke-Expression -Command $Text

    $arguments = @{ OutputPath = $OutputPath }
    if ($ConfigurationData)
    {
        $arguments['ConfigurationData'] = $ConfigurationData
    }

    $messages = & {
        try
        {
            $null = & $Name @arguments
        }
        catch
        {
            $_
        }
    } 2>&1

    (@($messages) | ForEach-Object -Process { $_.ToString() }) -join [System.Environment]::NewLine
}

<#
.SYNOPSIS
    Returns the MOF lines of a file with the volatile SourceInfo entries removed and sorted.

.PARAMETER Path
    Path of the MOF file to normalize.
#>
function Get-PSDscComparableMofLine
{
    [OutputType([System.String[]])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Path
    )

    Get-Content -Path $Path |
        ForEach-Object -Process { $_.Trim() } |
        Where-Object -FilterScript { $_ -and $_ -notmatch '^SourceInfo' } |
        Sort-Object
}

<#
.SYNOPSIS
    Runs a script block in a fresh runspace whose host discards ShouldProcess feedback.

.DESCRIPTION
    "What if:" and "Confirm:" feedback that ShouldProcess emits is written straight to the
    host, outside every redirectable stream, so Pester cannot capture it. A freshly created
    runspace gets a default host that does not surface that output, which lets a test that
    deliberately invokes -WhatIf run without leaking noise onto the console. The script
    block runs in a clean session, so it must import any module it uses itself.

.PARAMETER ScriptBlock
    The script block to run. Arguments from ArgumentList bind to its parameters.

.PARAMETER ArgumentList
    Arguments passed to the script block, bound positionally.
#>
function Invoke-PSDscQuiet
{
    [OutputType([System.Object[]])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.Management.Automation.ScriptBlock]
        $ScriptBlock,

        [Parameter(Position = 1)]
        [System.Object[]]
        $ArgumentList
    )

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $runspace.Open()
    try
    {
        $pipeline = [System.Management.Automation.PowerShell]::Create()
        try
        {
            $pipeline.Runspace = $runspace
            $null = $pipeline.AddScript($ScriptBlock.ToString())
            if ($ArgumentList)
            {
                foreach ($argument in $ArgumentList)
                {
                    $null = $pipeline.AddArgument($argument)
                }
            }
            return $pipeline.Invoke()
        }
        finally
        {
            $pipeline.Dispose()
        }
    }
    finally
    {
        $runspace.Dispose()
    }
}

<#
.SYNOPSIS
    Creates a document encryption certificate and exports its public key.

.DESCRIPTION
    Returns an object carrying the certificate, its thumbprint and the path of the exported
    public key file, or $null when the platform cannot issue such a certificate.

.PARAMETER PublicKeyPath
    Path the exported .cer public key file is written to.
#>
function New-PSDscDocumentEncryptionCertificate
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $PublicKeyPath
    )

    if (-not (Get-Command -Name 'New-SelfSignedCertificate' -ErrorAction Ignore))
    {
        return $null
    }

    try
    {
        $certificate = New-SelfSignedCertificate -Type DocumentEncryptionCert `
            -Subject 'CN=M365DSC.PSDesiredStateConfiguration Tests' `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyUsage KeyEncipherment, DataEncipherment `
            -NotAfter (Get-Date).AddDays(1) `
            -ErrorAction Stop
    }
    catch
    {
        return $null
    }

    $null = Export-Certificate -Cert $certificate -FilePath $PublicKeyPath -Force

    [PSCustomObject]@{
        Certificate   = $certificate
        Thumbprint    = $certificate.Thumbprint
        PublicKeyPath = $PublicKeyPath
        StorePath     = "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
    }
}

Export-ModuleMember -Function @(
    'Get-PSDscRepositoryRoot'
    'Get-PSDscEngineManifest'
    'Add-PSDscTestModulePath'
    'Restore-PSDscTestModulePath'
    'Import-PSDscEngine'
    'New-PSDscIsolatedTestModule'
    'Reset-PSDscFastHostState'
    'Invoke-PSDscInEngineScope'
    'Invoke-PSDscConfigurationText'
    'Get-PSDscDiagnosticText'
    'Get-PSDscCompilationDiagnostic'
    'Get-PSDscComparableMofLine'
    'New-PSDscDocumentEncryptionCertificate'
    'Invoke-PSDscQuiet'
)
