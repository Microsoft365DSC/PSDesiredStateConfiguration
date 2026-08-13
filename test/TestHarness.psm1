<#
.SYNOPSIS
    Runs the M365DSC.PSDesiredStateConfiguration Pester suites.

.DESCRIPTION
    Discovers every '*.Tests.ps1' suite under the test folder, puts the bundled test
    resource modules and the compatibility module on PSModulePath and runs the suites
    through Pester, optionally collecting code coverage over the module sources.

.PARAMETER TestResultsFile
    Path to write the NUnit test result file to. No file is written when omitted.

.PARAMETER DscTestsPath
    Runs only the suites at this path instead of every discovered suite.

.PARAMETER IgnoreCodeCoverage
    Skips code coverage collection.

.OUTPUTS
    The Pester run result object.
#>
function Invoke-TestHarness
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $TestResultsFile,

        [Parameter()]
        [System.String[]]
        $DscTestsPath,

        [Parameter()]
        [Switch]
        $IgnoreCodeCoverage
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host -Object 'Running all M365DSC.PSDesiredStateConfiguration Unit Tests'

    $repoDir = Join-Path -Path $PSScriptRoot -ChildPath '..\' -Resolve
    $moduleDir = Join-Path -Path $repoDir -ChildPath 'M365DSC.PSDesiredStateConfiguration'
    $manifestPath = Join-Path -Path $moduleDir -ChildPath 'M365DSC.PSDesiredStateConfiguration.psd1'

    $oldModulePath = $env:PSModulePath
    $separator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = (Join-Path -Path $PSScriptRoot -ChildPath 'TestModules') +
        $separator + (Join-Path -Path $moduleDir -ChildPath 'Compat') +
        $separator + $env:PSModulePath

    $testCoverageFiles = @()
    if ($IgnoreCodeCoverage.IsPresent -eq $false)
    {
        Get-ChildItem -Path $moduleDir -Include '*.psm1', '*.ps1' -Recurse |
            Where-Object { $_.FullName -notlike "*$([System.IO.Path]::DirectorySeparatorChar)Compat$([System.IO.Path]::DirectorySeparatorChar)*" } |
            ForEach-Object { $testCoverageFiles += $_.FullName }
    }

    # The suites import the engine themselves through PSDscTestHelper. Importing it here as
    # well would load it before code coverage starts, and its module level code would then be
    # reported as never executed.
    if (-not (Test-Path -LiteralPath $manifestPath))
    {
        throw "Module manifest not found at '$manifestPath'."
    }

    $filesToExecute = @()
    if ($DscTestsPath.Count -gt 0)
    {
        $filesToExecute += $DscTestsPath
    }
    else
    {
        $filesToExecute += @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -Recurse |
                Sort-Object -Property Name |
                ForEach-Object { $_.FullName })
    }

    $container = New-PesterContainer -Path $filesToExecute

    $configuration = [PesterConfiguration]@{
        Run    = @{
            Container = $container
            PassThru  = $true
        }
        Output = @{
            Verbosity = 'Normal'
        }
        Should = @{
            ErrorAction = 'Continue'
        }
    }

    if ([System.String]::IsNullOrEmpty($TestResultsFile) -eq $false)
    {
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = $TestResultsFile
    }

    if ($IgnoreCodeCoverage.IsPresent -eq $false)
    {
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = $testCoverageFiles
        $configuration.CodeCoverage.OutputPath = 'CodeCov.xml'
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
        $configuration.CodeCoverage.UseBreakpoints = $false
    }

    $results = Invoke-Pester -Configuration $configuration

    $message = 'Running the tests took {0} hours, {1} minutes, {2} seconds' -f $sw.Elapsed.Hours, $sw.Elapsed.Minutes, $sw.Elapsed.Seconds
    Write-Host -Object $message

    $env:PSModulePath = $oldModulePath
    Write-Host -Object 'Completed running all M365DSC.PSDesiredStateConfiguration Unit Tests'

    return $results
}

Export-ModuleMember -Function Invoke-TestHarness
