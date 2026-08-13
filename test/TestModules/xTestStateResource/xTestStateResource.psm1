[DscResource()]
class xTestStateResource
{
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [string] $Content

    [DscProperty()]
    [string] $Ensure = 'Present'

    [void] Set()
    {
        if ($this.Ensure -eq 'Absent')
        {
            if ([System.IO.File]::Exists($this.Path))
            {
                [System.IO.File]::Delete($this.Path)
            }
            return
        }

        [System.IO.File]::WriteAllText($this.Path, $this.Content)
    }

    [bool] Test()
    {
        if ($this.Ensure -eq 'Absent')
        {
            return -not [System.IO.File]::Exists($this.Path)
        }

        if (-not [System.IO.File]::Exists($this.Path))
        {
            return $false
        }

        return [System.IO.File]::ReadAllText($this.Path) -ceq $this.Content
    }

    [xTestStateResource] Get()
    {
        if ([System.IO.File]::Exists($this.Path))
        {
            $this.Content = [System.IO.File]::ReadAllText($this.Path)
            $this.Ensure = 'Present'
        }
        else
        {
            $this.Content = ''
            $this.Ensure = 'Absent'
        }

        return $this
    }
}
