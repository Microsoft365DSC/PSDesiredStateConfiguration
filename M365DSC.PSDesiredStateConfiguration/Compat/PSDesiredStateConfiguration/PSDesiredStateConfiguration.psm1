# Compatibility forwarder. The PowerShell engine resolves the module named
# PSDesiredStateConfiguration while it executes a configuration statement and then
# owns the qualified Configuration call the compiled body makes. This module claims
# that name and re-exports the commands of M365DSC.PSDesiredStateConfiguration, whose
# scriptblocks stay bound to their own module scope.

$script:EngineModuleName = 'M365DSC.PSDesiredStateConfiguration'
$script:ForwardedCommands = @(
    'Configuration'
    'New-DscChecksum'
    'Get-DscResource'
    'Invoke-DscResource'
    'Invoke-DscFastCompile'
    'Export-DscSchemaCache'
    'Test-DscSchemaCache'
    'Get-DscFastCompileTiming'
)

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
# An engine that imports this module while it is still loading itself is not visible
# to Get-Module yet, so it passes itself in through the handoff variable.
$script:EngineModule = $global:M365DscEngineHandoff
if (-not $script:EngineModule)
{
    $script:EngineModule = Get-Module -Name $script:EngineModuleName | Select-Object -First 1
}
if (-not $script:EngineModule)
{
    $script:EngineModule = Import-Module -Name (Resolve-EngineManifest) -PassThru
}

foreach ($command in $script:ForwardedCommands)
{
    $scriptBlock = & $script:EngineModule {
        param($name)
        (Get-Item -Path "function:$name" -ErrorAction Ignore).ScriptBlock
    } $command

    if ($scriptBlock)
    {
        Set-Item -Path "function:script:$command" -Value $scriptBlock
    }
}

Export-ModuleMember -Function $script:ForwardedCommands
