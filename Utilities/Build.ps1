<#
.SYNOPSIS
    Validates and tests the M365DSC.PSDesiredStateConfiguration module.

.DESCRIPTION
    The module is pure PowerShell script and is published straight from the
    M365DSC.PSDesiredStateConfiguration folder, so there is nothing to compile. This script
    keeps that folder publishable: it syncs the bundled compatibility module to the engine
    version, validates both manifests, verifies that the module imports and exports what its
    manifest promises, and optionally runs the Pester suites on both PowerShell editions.

.PARAMETER RepositoryRoot
    Root of the repository. Defaults to the parent of this script's folder.

.PARAMETER Test
    Run the Pester suites after validation.

.PARAMETER Edition
    Editions to run the suites on: Desktop (Windows PowerShell 5.1), Core (PowerShell 7), or both.
    Defaults to both.

.EXAMPLE
    PS> .\Utilities\Build.ps1
    Validates the module and the bundled compatibility module.

.EXAMPLE
    PS> .\Utilities\Build.ps1 -Test
    Validates, then runs every Pester suite on Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param
(
    [Parameter()]
    [System.String]
    $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [Parameter()]
    [Switch]
    $Test,

    [Parameter()]
    [ValidateSet('Desktop', 'Core')]
    [System.String[]]
    $Edition = @('Desktop', 'Core')
)

$ErrorActionPreference = 'Stop'

$moduleName = 'M365DSC.PSDesiredStateConfiguration'
$moduleRoot = Join-Path -Path $RepositoryRoot -ChildPath $moduleName
$manifestPath = Join-Path -Path $moduleRoot -ChildPath "$moduleName.psd1"
$compatRoot = Join-Path -Path $moduleRoot -ChildPath 'Compat\PSDesiredStateConfiguration'
$compatManifestPath = Join-Path -Path $compatRoot -ChildPath 'PSDesiredStateConfiguration.psd1'

function Write-BuildLog
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error')]
        [System.String]
        $Level = 'Info'
    )

    switch ($Level)
    {
        'Warning' { Write-Warning -Message $Message }
        'Error' { Write-Error -Message $Message }
        default { Write-Host -Object "  $Message" }
    }
}

Write-Host -Object "Building $moduleName"

#region Manifests

if (-not (Test-Path -Path $manifestPath))
{
    throw "Module manifest not found at '$manifestPath'."
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$version = $manifest.ModuleVersion
Write-BuildLog -Message "Version $version"

# The compatibility module claims the PSDesiredStateConfiguration name that the engine resolves
# while it executes a configuration statement, and must always ship at the engine's version.
$compatManifest = Import-PowerShellDataFile -Path $compatManifestPath
if ($compatManifest.ModuleVersion -ne $version)
{
    Write-BuildLog -Message "Syncing the compatibility module from $($compatManifest.ModuleVersion) to $version"
    $content = [System.IO.File]::ReadAllText($compatManifestPath)
    $content = $content -replace "moduleVersion\s*=\s*'[^']*'", "moduleVersion = '$version'"
    $content = $content -replace "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion = '$version'"
    [System.IO.File]::WriteAllText($compatManifestPath, $content)
}

$null = Test-ModuleManifest -Path $manifestPath
$null = Test-ModuleManifest -Path $compatManifestPath
Write-BuildLog -Message 'Manifests validated'

#endregion

#region Module surface

$probe = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$($manifestPath.Replace("'", "''"))' -Force
`$module = Get-Module -Name '$moduleName'
`$expected = @('$((@($manifest.FunctionsToExport) | Sort-Object) -join "','")')
`$missing = @(`$expected | Where-Object { -not `$module.ExportedFunctions.ContainsKey(`$_) })
if (`$missing.Count -gt 0)
{
    throw "The module does not export: `$(`$missing -join ', ')"
}
'OK:' + `$module.ExportedFunctions.Count
"@

foreach ($currentEdition in $Edition)
{
    $shell = if ($currentEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    if (-not (Get-Command -Name $shell -ErrorAction Ignore))
    {
        Write-BuildLog -Message "$shell is not available; skipping the $currentEdition surface check." -Level Warning
        continue
    }

    $result = & $shell -NoProfile -NonInteractive -Command $probe
    if ($LASTEXITCODE -ne 0)
    {
        throw "Module surface check failed on $currentEdition : $($result -join [Environment]::NewLine)"
    }
    $count = (@($result) | Where-Object { $_ -like 'OK:*' } | Select-Object -First 1) -replace '^OK:', ''
    Write-BuildLog -Message "$currentEdition exports $count functions"
}

#endregion

#region Tests

if ($Test)
{
    $testRoot = Join-Path -Path $RepositoryRoot -ChildPath 'test'
    $suites = @(Get-ChildItem -Path $testRoot -Filter '*.Tests.ps1' | Sort-Object -Property Name)
    $suiteList = ($suites.FullName | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','

    $runner = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name Pester -MinimumVersion 5.0
# Resource modules and the compatibility module are resolved by name while a configuration runs.
`$env:PSModulePath = '$($moduleRoot.Replace("'", "''"))\Compat' + [System.IO.Path]::PathSeparator +
    '$($testRoot.Replace("'", "''"))\TestModules' + [System.IO.Path]::PathSeparator + `$env:PSModulePath
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($suiteList)
`$configuration.Run.PassThru = `$true
`$configuration.Output.Verbosity = 'Normal'
`$result = Invoke-Pester -Configuration `$configuration
'RESULT:{0}:{1}' -f `$result.PassedCount, `$result.FailedCount
"@

    foreach ($currentEdition in $Edition)
    {
        $shell = if ($currentEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
        if (-not (Get-Command -Name $shell -ErrorAction Ignore))
        {
            Write-BuildLog -Message "$shell is not available; skipping the $currentEdition test run." -Level Warning
            continue
        }

        Write-Host -Object "Running $($suites.Count) suites on $currentEdition"
        $output = & $shell -NoProfile -NonInteractive -Command $runner
        $output | ForEach-Object { Write-Host -Object $_ }

        $summary = (@($output) | Where-Object { $_ -like 'RESULT:*' } | Select-Object -First 1)
        if (-not $summary)
        {
            throw "The $currentEdition test run produced no result."
        }
        $parts = $summary.Split(':')
        if ([int]$parts[2] -gt 0)
        {
            throw "$($parts[2]) test(s) failed on $currentEdition."
        }
        Write-BuildLog -Message "$currentEdition : $($parts[1]) passed"
    }
}

#endregion

Write-Host -Object "$moduleName $version is ready to publish from $moduleRoot"
