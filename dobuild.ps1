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

    Write-Verbose -Verbose -Message "Ending DoBuild"
}
