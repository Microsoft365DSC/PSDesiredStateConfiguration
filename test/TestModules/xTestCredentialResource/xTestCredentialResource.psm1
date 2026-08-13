[DscResource()]
class xTestCredentialResource
{
    [DscProperty(Key)]
    [string] $Name

    [DscProperty()]
    [PSCredential] $Credential

    [DscProperty()]
    [string] $Value

    [void] Set()
    {
    }

    [bool] Test()
    {
        return $true
    }

    [xTestCredentialResource] Get()
    {
        return $this
    }
}
