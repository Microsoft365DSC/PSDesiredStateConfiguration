@{
    RootModule           = 'xTestStateResource.psm1'
    ModuleVersion        = '1.0'
    GUID                 = '6bd4b2f1-2e6a-4c58-9f22-64f7c1de5a04'
    Author               = 'PSDesiredStateConfiguration Tests'
    CompanyName          = 'Community'
    Copyright            = '(c) PSDesiredStateConfiguration Tests. All rights reserved.'
    Description          = 'A class-based DSC resource that keeps a file in the requested state.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = '*'
    DscResourcesToExport = @('xTestStateResource')
}
