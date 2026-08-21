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

    Write-TestHarnessSummary -Result $results

    return $results
}

<#
.SYNOPSIS
    Renders the results of Invoke-TestHarness as a report.

.DESCRIPTION
    Writes the test counts and the per file code coverage of the run. Without a path the report
    goes to the console, with a path it is appended as GitHub flavoured markdown, which makes it
    usable as a GitHub Actions step summary.

.PARAMETER Result
    The object returned by Invoke-TestHarness.

.PARAMETER Path
    File to append the markdown report to.

.EXAMPLE
    Write-TestHarnessSummary -Result $results -Path $env:GITHUB_STEP_SUMMARY
#>
function Write-TestHarnessSummary
{
    [CmdletBinding()]
    [OutputType([System.Void])]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]
        $Result,

        [Parameter()]
        [System.String]
        $Path
    )

    $lines = [System.Collections.Generic.List[System.String]]::new()

    $lines.Add('## Unit Test Results')
    $lines.Add('')
    $lines.Add('| Passed | Failed | Skipped |')
    $lines.Add('| ---: | ---: | ---: |')
    $lines.Add("| $($Result.PassedCount) | $($Result.FailedCount) | $($Result.SkippedCount) |")
    $lines.Add('')

    $coverage = $Result.CodeCoverage
    if ($null -ne $coverage)
    {
        $lines.Add('## Code Coverage')
        $lines.Add('')
        $lines.Add("**$([System.Math]::Round($coverage.CoveragePercent, 2))%** of $($coverage.CommandsAnalyzedCount) commands covered.")
        $lines.Add('')
        $lines.Add('| File | Covered | Missed |')
        $lines.Add('| :--- | ---: | ---: |')

        $perFile = @{}
        foreach ($command in @($coverage.CommandsExecuted) + @($coverage.CommandsMissed))
        {
            if ($null -eq $command)
            {
                continue
            }

            if (-not $perFile.ContainsKey($command.File))
            {
                $perFile[$command.File] = @{ Analyzed = 0; Missed = 0 }
            }

            $perFile[$command.File].Analyzed++
        }

        foreach ($command in @($coverage.CommandsMissed))
        {
            if ($null -eq $command)
            {
                continue
            }

            $perFile[$command.File].Missed++
        }

        foreach ($file in ($perFile.Keys | Sort-Object))
        {
            $analyzed = $perFile[$file].Analyzed
            $missed = $perFile[$file].Missed
            $percentage = [System.Math]::Round(($analyzed - $missed) / $analyzed * 100, 2)
            $lines.Add("| $(Split-Path -Path $file -Leaf) | $percentage% | $missed |")
        }

        $lines.Add('')
    }

    if ([System.String]::IsNullOrEmpty($Path))
    {
        $lines | ForEach-Object { Write-Host -Object $_ }
    }
    else
    {
        $lines | Out-File -FilePath $Path -Append -Encoding utf8
    }
}

Export-ModuleMember -Function Invoke-TestHarness, Write-TestHarnessSummary
