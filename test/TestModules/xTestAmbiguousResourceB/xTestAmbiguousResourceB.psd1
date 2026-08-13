@{
    RootModule           = 'xTestAmbiguousResourceB.psm1'
    ModuleVersion        = '1.0'
    GUID                 = 'b3f6a97c-15d4-4e02-8f7a-51c9d0e4b6a2'
    Author               = 'PSDesiredStateConfiguration Tests'
    CompanyName          = 'Community'
    Copyright            = '(c) PSDesiredStateConfiguration Tests. All rights reserved.'
    Description          = 'Second of two modules exporting the same DSC resource name.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = '*'
    DscResourcesToExport = @('xTestAmbiguousResource')
}
