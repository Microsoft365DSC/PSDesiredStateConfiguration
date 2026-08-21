BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSDscTestHelper.psm1') -Force
    Add-PSDscTestModulePath
    Import-PSDscEngine

    $script:OriginalProgressPreference = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
}

AfterAll {
    $global:ProgressPreference = $script:OriginalProgressPreference
    Restore-PSDscTestModulePath
}

Describe 'Get-DscResource module selection' {
    It 'accepts a module name' {
        $resources = Get-DscResource -Module xTestClassResource

        $resources.Name | Should -Contain 'xTestClassResource'
        $resources.Name | Should -Contain 'ResourceForTests1'
        $resources.Name | Should -Contain 'ResourceForTests2'
        $resources.Name | Should -Contain 'ResourceForTests3'
        $resources.Module.Name | Should -Not -Contain 'xTestScriptResource'
    }

    It 'accepts a module specification hashtable' {
        $resources = Get-DscResource -Name ResourceForTests1 -Module @{ ModuleName = 'xTestClassResource'; RequiredVersion = '1.0' }

        @($resources).Count | Should -Be 1
        $resources.Module.Version | Should -Be ([version]'1.0')
    }

    It 'accepts a ModuleSpecification object' {
        $specification = [Microsoft.PowerShell.Commands.ModuleSpecification]::new('xTestClassResource')
        $resources = Get-DscResource -Name ResourceForTests2 -Module $specification

        @($resources).Count | Should -Be 1
        $resources.Name | Should -Be 'ResourceForTests2'
    }

    It 'warns when no module matches the specification' {
        $warnings = @()
        $resources = Get-DscResource -Module 'xTestModuleThatDoesNotExist' -WarningVariable warnings -WarningAction SilentlyContinue

        $resources | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'no modules present'
    }

    It 'reports a resource name that no module provides' {
        $errors = @()
        $null = Get-DscResource -Name 'xTestResourceThatDoesNotExist' -Module xTestClassResource -ErrorVariable errors -ErrorAction SilentlyContinue

        ($errors -join ' ') | Should -Match "'xTestResourceThatDoesNotExist' is not recognized"
    }

    It 'matches resource names with a wildcard' {
        $resources = Get-DscResource -Name 'ResourceForTests*' -Module xTestClassResource

        @($resources).Count | Should -Be 3
    }

    It 'takes the resource name from the pipeline' {
        $resources = 'ResourceForTests3' | Get-DscResource -Module xTestClassResource

        $resources.Name | Should -Be 'ResourceForTests3'
    }
}

Describe 'Get-DscResource implementation details' {
    It 'describes a class based resource' {
        $resource = Get-DscResource -Name ResourceForTests1 -Module xTestClassResource

        $resource.ImplementationDetail | Should -Be 'ClassBased'
        $resource.ImplementedAs | Should -Be 'PowerShell'
        $resource.ResourceType | Should -Be 'ResourceForTests1'
        $resource.Path | Should -BeLike '*xTestClassResource.psd1'
        $resource.Module.Name | Should -Be 'xTestClassResource'
    }

    It 'describes a script based resource' {
        $resource = Get-DscResource -Name xTestScriptResource -Module xTestScriptResource

        $resource.ImplementationDetail | Should -Be 'ScriptBased'
        $resource.ImplementedAs | Should -Be 'PowerShell'
        $resource.ResourceType | Should -Be 'MSFT_xTestScriptResource'
        $resource.FriendlyName | Should -Be 'xTestScriptResource'
        $resource.Path | Should -BeLike '*MSFT_xTestScriptResource.psm1'
        $resource.ParentPath | Should -BeLike '*DscResources\MSFT_xTestScriptResource'
        ($resource.Properties | Where-Object { $_.Name -eq 'Ensure' }).Values -join ',' | Should -Be 'Absent,Present'
    }

    It 'describes a composite resource' {
        $resource = Get-DscResource -Name xTestComposite -Module xTestCompositeResource

        $resource | Should -Not -BeNullOrEmpty
        $resource.ImplementedAs | Should -Be 'Composite'
        $resource.Path | Should -BeLike '*xTestComposite.schema.psm1'
        $resource.Properties.Name | Should -Contain 'Marker'
    }

    It 'sorts mandatory properties first' {
        $resource = Get-DscResource -Name xTestClassResource -Module xTestClassResource

        $mandatory = @($resource.Properties | Where-Object { $_.IsMandatory })
        $mandatory.Count | Should -BeGreaterThan 0
        @($resource.Properties)[0..($mandatory.Count - 1)].Name | Should -Be $mandatory.Name
    }
}

Describe 'Get-DscResource -Syntax' {
    It 'renders the resource as a keyword body' {
        $syntax = Get-DscResource -Name xTestScriptResource -Module xTestScriptResource -Syntax

        $syntax | Should -BeOfType ([System.String])
        $syntax | Should -Match 'xTestScriptResource \[String\] #ResourceName'
        $syntax | Should -Match 'Name = \[string\]'
        $syntax | Should -Match '\[Ensure = \[string\]\{ Absent \| Present \}\]'
        $syntax | Should -Match '\[DependsOn = \[string\[\]\]\]'
    }

    It 'renders one syntax block per resource' {
        $syntax = @(Get-DscResource -Module xTestClassResource -Syntax)
        $resources = @(Get-DscResource -Module xTestClassResource)

        $syntax.Count | Should -Be $resources.Count
    }
}

Describe 'Invoke-DscResource on a script based resource' {
    It 'returns the Get-TargetResource hashtable' {
        $result = Invoke-DscResource -Name xTestScriptResource -ModuleName xTestScriptResource -Method Get -Property @{ Name = 'probe' }

        $result | Should -BeOfType ([hashtable])
        $result.Name | Should -Be 'probe'
        $result.Ensure | Should -Be 'Present'
    }

    It 'wraps the Test-TargetResource result' {
        $result = Invoke-DscResource -Name xTestScriptResource -ModuleName xTestScriptResource -Method Test -Property @{ Name = 'probe' }

        $result.GetType().Name | Should -Be 'InvokeDscResourceTestResult'
        $result.InDesiredState | Should -BeTrue
    }

    It 'wraps the Set-TargetResource result' {
        $result = Invoke-DscResource -Name xTestScriptResource -ModuleName xTestScriptResource -Method Set -Property @{ Name = 'probe' }

        $result.GetType().Name | Should -Be 'InvokeDscResourceSetResult'
        $result.RebootRequired | Should -BeFalse
    }
}

Describe 'Invoke-DscResource error handling' {
    It 'throws when the resource name is ambiguous' {
        { Invoke-DscResource -Name xTestAmbiguousResource -Method Get -Property @{ Name = 'probe' } } |
            Should -Throw -ExpectedMessage '*Found more than one resource named*'
    }

    It 'throws when the resource does not exist' {
        { Invoke-DscResource -Name xTestResourceThatDoesNotExist -ModuleName xTestClassResource -Method Get -Property @{ Name = 'probe' } } |
            Should -Throw
    }
}
