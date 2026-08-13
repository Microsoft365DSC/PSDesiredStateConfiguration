[DscResource()]
class xTestAmbiguousResource
{
    [DscProperty(Key)]
    [string] $Name

    [void] Set()
    {
    }

    [bool] Test()
    {
        return $true
    }

    [xTestAmbiguousResource] Get()
    {
        return $this
    }
}
