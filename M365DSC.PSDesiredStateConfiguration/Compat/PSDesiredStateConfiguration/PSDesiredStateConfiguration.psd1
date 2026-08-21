#
# Compatibility manifest that claims the PSDesiredStateConfiguration module name for
# M365DSC.PSDesiredStateConfiguration. Keep ModuleVersion in lockstep with it.
#
@{

    RootModule = 'PSDesiredStateConfiguration.psm1'

    ModuleVersion = '3.1.2'

    CompatiblePSEditions = @('Desktop', 'Core')

    GUID = '0c5b1a6f-4d38-4c0c-9c68-2f6a1d9a7b45'

    Author = 'Microsoft365DSC'

    CompanyName = 'Microsoft365DSC'

    Copyright = '(c) Microsoft Corporation. All rights reserved.'

    Description = 'Compatibility shim that routes the PSDesiredStateConfiguration module name to M365DSC.PSDesiredStateConfiguration.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
            'Configuration'
            'New-DscChecksum'
            'Get-DscResource'
            'Invoke-DscResource'
            'Invoke-DscFastCompile'
            'Export-DscSchemaCache'
            'Test-DscSchemaCache'
        )

    CmdletsToExport = @()

    VariablesToExport = @()

    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('PSDesiredStateConfiguration', 'M365DSCFastHost', 'Windows')
            ProjectUri = 'https://github.com/Microsoft365DSC/PSDesiredStateConfiguration'
        }
    }
}
