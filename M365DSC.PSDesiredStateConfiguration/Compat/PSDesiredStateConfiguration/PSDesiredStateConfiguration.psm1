# Compatibility forwarder. The PowerShell engine resolves the module named
# PSDesiredStateConfiguration while it executes a configuration statement and then
# owns the qualified Configuration call the compiled body makes. This module claims
# that name and re-exports the commands of M365DSC.PSDesiredStateConfiguration, whose
# scriptblocks stay bound to their own module scope.

$script:EngineModuleName = 'M365DSC.PSDesiredStateConfiguration'

function Resolve-EngineManifest
{
    [OutputType([string])]
    param()

    # This module ships inside the engine, at <engineRoot>\Compat\PSDesiredStateConfiguration,
    # so the engine manifest sits two levels up. The sibling layouts are kept as fallbacks for
    # installations that place the two modules next to each other.
    $engineRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $candidates = @(
        (Join-Path $engineRoot "$script:EngineModuleName.psd1")
        (Join-Path (Split-Path $PSScriptRoot -Parent) "$script:EngineModuleName\$script:EngineModuleName.psd1")
        (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "$script:EngineModuleName\$(Split-Path $PSScriptRoot -Leaf)\$script:EngineModuleName.psd1")
    )
    foreach ($candidate in $candidates)
    {
        if (Test-Path -Path $candidate)
        {
            return $candidate
        }
    }

    $installed = Get-Module -ListAvailable -Name $script:EngineModuleName |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($installed)
    {
        return $installed.Path
    }

    throw "The $script:EngineModuleName module could not be found next to this compatibility module or on PSModulePath."
}

# Never reload an already-loaded engine: a second instance would carry its own
# keyword and fast host state, and configurations would run against the wrong one.
$script:EngineModule = Get-Module -Name $script:EngineModuleName | Select-Object -First 1
if (-not $script:EngineModule)
{
    $script:EngineModule = Import-Module -Name (Resolve-EngineManifest) -PassThru
}

foreach ($exported in $script:EngineModule.ExportedFunctions.GetEnumerator())
{
    Set-Item -Path "function:script:$($exported.Key)" -Value $exported.Value.ScriptBlock
}

Export-ModuleMember -Function @($script:EngineModule.ExportedFunctions.Keys)
