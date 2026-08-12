function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter()]
        [ValidateSet('Present', 'Absent')]
        [string]
        $Ensure = 'Present',

        [Parameter()]
        [string[]]
        $Items
    )

    return @{
        Name   = $Name
        Ensure = $Ensure
        Items  = [string[]]@()
    }
}

function Set-TargetResource
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter()]
        [ValidateSet('Present', 'Absent')]
        [string]
        $Ensure = 'Present',

        [Parameter()]
        [string[]]
        $Items
    )

    Write-Verbose -Message "Set called for $Name"
}

function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter()]
        [ValidateSet('Present', 'Absent')]
        [string]
        $Ensure = 'Present',

        [Parameter()]
        [string[]]
        $Items
    )

    return $true
}

Export-ModuleMember -Function Get-TargetResource, Set-TargetResource, Test-TargetResource
