# Measures DSC MOF compile times across editions (WinPS 5.1 / PS7), compile paths
# (builtin module, fork standard, fork fast host) and cache states. Every sample runs
# in a fresh child process; one warm-up run per cell is discarded and the median of
# the remaining runs is reported.
[CmdletBinding()]
param (
    [ValidateSet('5.1', '7')]
    [string[]]
    $Edition = @('5.1', '7'),

    [ValidateSet('builtin', 'fork-standard', 'fork-fasthost')]
    [string[]]
    $CompilePath = @('builtin', 'fork-standard', 'fork-fasthost'),

    [ValidateSet('cold', 'warm-session')]
    [string[]]
    $State = @('cold', 'warm-session'),

    [string]
    $ConfigPath,

    [int]
    $Repetition = 3,

    [string]
    $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$srcParent = Join-Path -Path $repoRoot -ChildPath 'src'
$testModules = Join-Path -Path $repoRoot -ChildPath 'test\TestModules'
foreach ($required in @($srcParent, $testModules))
{
    if (-not (Test-Path -Path $required))
    {
        throw "Expected repository directory not found: $required"
    }
}

if ($ConfigPath)
{
    $configText = [System.IO.File]::ReadAllText((Resolve-Path -Path $ConfigPath).ProviderPath)
}
else
{
    $configText = @'
Configuration DscBenchConfig
{
    Import-DscResource -ModuleName xTestClassResource

    Node localhost
    {
        xTestClassResource Instance1
        {
            Name = 'Instance1'
            Value = 'Value1'
            Ensure = 'Present'
            sArray = @('s1', 's2')
        }

        ResourceForTests1 Instance2
        {
            Prop1 = 'Prop1-Instance2'
        }

        ResourceForTests2 Instance3
        {
            Prop1 = 'Prop1-Instance3'
        }
    }
}
'@
}

$nameMatch = [regex]::Match($configText, '(?im)^\s*Configuration\s+([A-Za-z_][A-Za-z0-9_]*)')
if (-not $nameMatch.Success)
{
    throw 'Could not determine the configuration name from the configuration text.'
}
$configName = $nameMatch.Groups[1].Value

$moduleNames = @()
foreach ($m in [regex]::Matches($configText, "(?i)Import-DscResource\s+-ModuleName\s+'?([A-Za-z0-9_.]+)'?"))
{
    if ($moduleNames -notcontains $m.Groups[1].Value)
    {
        $moduleNames += $m.Groups[1].Value
    }
}

$childTemplate = @'
$ErrorActionPreference = 'Stop'
$sep = [System.IO.Path]::PathSeparator
$pathKind = '__PATHKIND__'
$state = '__STATE__'
$srcParent = '__SRCPARENT__'
$testModules = '__TESTMODULES__'
$outRoot = '__OUTROOT__'
$configName = '__CONFIGNAME__'
$moduleNames = @(__MODULENAMES__)
$configText = [System.IO.File]::ReadAllText('__CONFIGFILE__')

function Test-MofPresent
{
    param ([string]$Dir)
    if (-not (Test-Path -Path $Dir) -or @(Get-ChildItem -Path $Dir -Filter '*.mof').Count -eq 0)
    {
        throw "No .mof file was produced in $Dir."
    }
}

try
{
    $entries = @($env:PSModulePath -split [regex]::Escape($sep) | Where-Object { $_ -and $_ -ne $srcParent -and $_ -ne $testModules })
    $prepend = @()
    if ($pathKind -ne 'builtin') { $prepend += $srcParent }
    $prepend += $testModules
    $env:PSModulePath = (($prepend + $entries) -join $sep)

    if (Test-Path -Path $outRoot) { Remove-Item -Path $outRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $outRoot -Force

    if ($pathKind -eq 'fork-fasthost')
    {
        if ($state -eq 'cold')
        {
            $cacheDir = Join-Path -Path ([System.Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'PSDesiredStateConfiguration\SchemaCache'
            if (Test-Path -Path $cacheDir)
            {
                foreach ($m in $moduleNames)
                {
                    Get-ChildItem -Path $cacheDir -Filter ($m + '_*.json') -ErrorAction SilentlyContinue | Remove-Item -Force
                }
            }
        }
        Import-Module -Name PSDesiredStateConfiguration -MinimumVersion 3.0 -Force
        $out1 = Join-Path -Path $outRoot -ChildPath 'r1'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-DscFastCompile -ScriptText $configText -ConfigurationName $configName -OutputPath $out1 -NoFallback
        $compileSec = $sw.Elapsed.TotalSeconds
        Test-MofPresent -Dir $out1
        $parseSec = 0.0
        if ($state -eq 'warm-session')
        {
            $out2 = Join-Path -Path $outRoot -ChildPath 'r2'
            $sw.Restart()
            $null = Invoke-DscFastCompile -ScriptText $configText -ConfigurationName $configName -OutputPath $out2 -NoFallback
            $compileSec = $sw.Elapsed.TotalSeconds
            Test-MofPresent -Dir $out2
        }
    }
    else
    {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $sb = [scriptblock]::Create($configText)
        . $sb
        $parseSec = $sw.Elapsed.TotalSeconds
        $out1 = Join-Path -Path $outRoot -ChildPath 'r1'
        $sw.Restart()
        $null = & $configName -OutputPath $out1
        $compileSec = $sw.Elapsed.TotalSeconds
        Test-MofPresent -Dir $out1
        if ($state -eq 'warm-session')
        {
            $sw.Restart()
            $sb2 = [scriptblock]::Create($configText)
            . $sb2
            $parseSec = $sw.Elapsed.TotalSeconds
            $out2 = Join-Path -Path $outRoot -ChildPath 'r2'
            $sw.Restart()
            $null = & $configName -OutputPath $out2
            $compileSec = $sw.Elapsed.TotalSeconds
            Test-MofPresent -Dir $out2
        }
    }
    Write-Output ('##RESULT## ' + (ConvertTo-Json -InputObject @{ parseSec = [math]::Round($parseSec, 4); compileSec = [math]::Round($compileSec, 4) } -Compress))
}
catch
{
    $message = [regex]::Replace($_.Exception.Message, '\s+', ' ').Trim()
    if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
    Write-Output ('##RESULT## ' + (ConvertTo-Json -InputObject @{ error = $message } -Compress))
    exit 1
}
finally
{
    if (Test-Path -Path $outRoot) { Remove-Item -Path $outRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
'@

function Get-Median
{
    param ([double[]]$Values)

    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1)
    {
        return [math]::Round($sorted[($n - 1) / 2], 4)
    }
    [math]::Round((($sorted[($n / 2) - 1] + $sorted[$n / 2]) / 2.0), 4)
}

function ConvertTo-SingleQuoted
{
    param ([string]$Value)
    $Value.Replace("'", "''")
}

$workRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dscbench-' + [System.Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workRoot -Force
$configFile = Join-Path -Path $workRoot -ChildPath 'benchconfig.ps1.txt'
[System.IO.File]::WriteAllText($configFile, $configText, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

$moduleNameLiteral = ''
if ($moduleNames.Count -gt 0)
{
    $moduleNameLiteral = "'" + (($moduleNames | ForEach-Object { ConvertTo-SingleQuoted -Value $_ }) -join "', '") + "'"
}

$rows = @()
try
{
    foreach ($currentEdition in $Edition)
    {
        if ($currentEdition -eq '5.1') { $exe = 'powershell.exe' } else { $exe = 'pwsh' }
        foreach ($currentPath in $CompilePath)
        {
            foreach ($currentState in $State)
            {
                $cellId = ('{0}_{1}_{2}' -f $currentEdition, $currentPath, $currentState).Replace('.', '_')
                $childPath = Join-Path -Path $workRoot -ChildPath ('run_' + $cellId + '.ps1')
                $outRoot = Join-Path -Path $workRoot -ChildPath ('out_' + $cellId)
                $childScript = $childTemplate
                $childScript = $childScript.Replace('__PATHKIND__', $currentPath)
                $childScript = $childScript.Replace('__STATE__', $currentState)
                $childScript = $childScript.Replace('__SRCPARENT__', (ConvertTo-SingleQuoted -Value $srcParent))
                $childScript = $childScript.Replace('__TESTMODULES__', (ConvertTo-SingleQuoted -Value $testModules))
                $childScript = $childScript.Replace('__OUTROOT__', (ConvertTo-SingleQuoted -Value $outRoot))
                $childScript = $childScript.Replace('__CONFIGNAME__', (ConvertTo-SingleQuoted -Value $configName))
                $childScript = $childScript.Replace('__MODULENAMES__', $moduleNameLiteral)
                $childScript = $childScript.Replace('__CONFIGFILE__', (ConvertTo-SingleQuoted -Value $configFile))
                [System.IO.File]::WriteAllText($childPath, $childScript, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

                Write-Verbose -Message "Running $currentEdition/$currentPath/$currentState ($($Repetition + 1) child runs, first discarded)."
                $parseSamples = @()
                $compileSamples = @()
                $cellError = $null
                for ($run = 0; $run -le $Repetition; $run++)
                {
                    $previousEap = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try
                    {
                        $stdout = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $childPath 2>&1 | ForEach-Object { [string]$_ })
                    }
                    finally
                    {
                        $ErrorActionPreference = $previousEap
                    }
                    $resultLine = $stdout | Where-Object { $_ -like '##RESULT##*' } | Select-Object -Last 1
                    if (-not $resultLine)
                    {
                        $cellError = 'No result emitted by child process. Tail: ' + (($stdout | Select-Object -Last 3) -join ' | ')
                        break
                    }
                    $result = ConvertFrom-Json -InputObject $resultLine.Substring('##RESULT##'.Length).Trim()
                    if ($result.PSObject.Properties['error'])
                    {
                        $cellError = $result.error
                        break
                    }
                    if ($run -gt 0)
                    {
                        $parseSamples += [double]$result.parseSec
                        $compileSamples += [double]$result.compileSec
                    }
                }

                if ($cellError)
                {
                    $row = [PSCustomObject]@{
                        Edition    = $currentEdition
                        Path       = $currentPath
                        State      = $currentState
                        ParseSec   = $null
                        CompileSec = $null
                        TotalSec   = $null
                        Error      = $cellError
                    }
                }
                else
                {
                    $parseMedian = Get-Median -Values $parseSamples
                    $compileMedian = Get-Median -Values $compileSamples
                    $row = [PSCustomObject]@{
                        Edition    = $currentEdition
                        Path       = $currentPath
                        State      = $currentState
                        ParseSec   = $parseMedian
                        CompileSec = $compileMedian
                        TotalSec   = [math]::Round($parseMedian + $compileMedian, 4)
                        Error      = ''
                    }
                }
                $row
                $rows += , $row
            }
        }
    }
}
finally
{
    Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($OutputPath -and $rows.Count -gt 0)
{
    $rows | Export-Csv -Path $OutputPath -NoTypeInformation
}

if (@($rows | Where-Object { $_.Error }).Count -gt 0)
{
    exit 1
}
exit 0
