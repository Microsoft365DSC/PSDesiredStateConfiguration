@{
    RootModule           = 'xTestAmbiguousResourceA.psm1'
    ModuleVersion        = '1.0'
    GUID                 = 'd8a1c4e0-7b52-4a3f-9d81-3c6e5b2a9f10'
    Author               = 'PSDesiredStateConfiguration Tests'
    CompanyName          = 'Community'
    Copyright            = '(c) PSDesiredStateConfiguration Tests. All rights reserved.'
    Description          = 'First of two modules exporting the same DSC resource name.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = '*'
    DscResourcesToExport = @('xTestAmbiguousResource')
}
