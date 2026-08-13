@{
    RootModule           = 'xTestCredentialResource.psm1'
    ModuleVersion        = '1.0'
    GUID                 = '0f5a3a5d-4c9f-4a1e-9a3f-2f4a1d6b7c31'
    Author               = 'PSDesiredStateConfiguration Tests'
    CompanyName          = 'Community'
    Copyright            = '(c) PSDesiredStateConfiguration Tests. All rights reserved.'
    Description          = 'A class-based DSC resource carrying a PSCredential property.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = '*'
    DscResourcesToExport = @('xTestCredentialResource')
}
