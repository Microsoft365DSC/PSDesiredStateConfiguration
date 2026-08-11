# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

#####################################################
# Do NOT edit anything outside the DoBuild function.
# You can define functions inside the scope of DoBuild.
#####################################################

<#
.DESCRIPTION
Implement build and packaging of the package and place the output $OutDirectory/$ModuleName
#>
function DoBuild
{
    Write-Verbose -Verbose -Message "Starting DoBuild"

    Write-Verbose -Verbose -Message "Copying module files to '${OutDirectory}/${ModuleName}'"
    # The module is pure script - packaging is a plain copy of the source tree.
    copy-item "${SrcPath}/*" "${OutDirectory}/${ModuleName}" -Recurse

    # The compatibility module claims the PSDesiredStateConfiguration name that the
    # engine resolves while it executes a configuration statement.
    $compatSource = Join-Path (Split-Path $SrcPath -Parent) 'PSDesiredStateConfiguration'
    $compatTarget = Join-Path $OutDirectory 'PSDesiredStateConfiguration'
    if (Test-Path $compatSource)
    {
        Write-Verbose -Verbose -Message "Copying compatibility module to '$compatTarget'"
        $null = New-Item -Path $compatTarget -ItemType Directory -Force
        copy-item "$compatSource/*" $compatTarget -Recurse -Force

        $engineVersion = (Import-PowerShellDataFile "${SrcPath}/${ModuleName}.psd1").ModuleVersion
        $compatVersion = (Import-PowerShellDataFile "$compatSource/PSDesiredStateConfiguration.psd1").ModuleVersion
        if ($engineVersion -ne $compatVersion)
        {
            throw "Compatibility module version $compatVersion does not match ${ModuleName} version $engineVersion."
        }
    }

    Write-Verbose -Verbose -Message "Ending DoBuild"
}
