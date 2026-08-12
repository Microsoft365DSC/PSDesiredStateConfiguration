Configuration xTestComposite
{
    param (
        [string]
        $Marker
    )

    Import-DscResource -ModuleName xTestClassResource

    ResourceForTests1 comp
    {
        Prop1 = $Marker
    }
}
