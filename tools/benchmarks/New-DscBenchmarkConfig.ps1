# Generates a synthetic DSC configuration script from a schema cache JSON.
# Emits only the Configuration block (no trailing invocation) plus a .meta.json sidecar.
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]
    $SchemaCachePath,

    [int]
    $InstanceCount = 5,

    [int]
    $ResourceSpread = 3,

    [Parameter(Mandatory)]
    [string]
    $OutputPath,

    [string]
    $ModuleName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$simpleTypes = @('String', 'Boolean', 'StringArray', 'SInt32', 'UInt32')

$cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Resolve-Path -Path $SchemaCachePath).ProviderPath))
if (-not $ModuleName)
{
    $ModuleName = $cache.module.name
}

function Get-KeywordProperties
{
    param ($Keyword)

    $result = @()
    foreach ($item in $Keyword.properties.PSObject.Properties)
    {
        $result += , $item.Value
    }
    , $result
}

$candidates = @()
foreach ($keyword in $cache.keywords)
{
    if ($keyword.nameMode -ne 'NameRequired') { continue }
    $properties = Get-KeywordProperties -Keyword $keyword
    $required = @($properties | Where-Object { $_.mandatory -or $_.isKey })
    $allSimple = $true
    foreach ($property in $required)
    {
        if ($simpleTypes -notcontains $property.typeConstraint)
        {
            $allSimple = $false
            break
        }
    }
    if (-not $allSimple -or $required.Count -eq 0) { continue }
    $uniqueKey = @($required | Where-Object { $_.isKey -and $_.typeConstraint -eq 'String' -and @($_.values).Count -eq 0 }).Count -gt 0
    $candidates += , ([PSCustomObject]@{
            Keyword   = $keyword
            Required  = $required
            UniqueKey = $uniqueKey
        })
}

if ($candidates.Count -eq 0)
{
    throw "Schema cache '$SchemaCachePath' contains no NameRequired keyword whose mandatory/key properties are all simple types ($($simpleTypes -join ', '))."
}

$ordered = @($candidates | Sort-Object -Property @{ Expression = { -not $_.UniqueKey } }, @{ Expression = { $_.Keyword.keyword } })
$chosen = @($ordered | Select-Object -First $ResourceSpread)
if ($chosen.Count -lt $ResourceSpread)
{
    Write-Warning -Message "Only $($chosen.Count) of $ResourceSpread requested keywords qualify; using all of them."
}
foreach ($entry in $chosen)
{
    if (-not $entry.UniqueKey -and $InstanceCount -gt $chosen.Count)
    {
        Write-Warning -Message "Keyword '$($entry.Keyword.keyword)' has no values-unconstrained String key; duplicate key values across instances may fail conflict checks."
    }
}

function Get-PropertyLiteral
{
    param ($Property, [int]$InstanceNumber)

    $values = @($Property.values)
    if ($values.Count -gt 0)
    {
        return "'" + ([string]$values[0]).Replace("'", "''") + "'"
    }
    switch ($Property.typeConstraint)
    {
        'String'
        {
            if ($Property.isKey)
            {
                return "'" + $Property.name + "-Instance" + $InstanceNumber + "'"
            }
            return "'" + $Property.name + "-Value'"
        }
        'Boolean' { return '$true' }
        'SInt32'
        {
            if ($Property.isKey) { return [string]$InstanceNumber }
            return '1'
        }
        'UInt32'
        {
            if ($Property.isKey) { return [string]$InstanceNumber }
            return '1'
        }
        'StringArray' { return "@('s1', 's2')" }
        default { throw "Unsupported type constraint '$($Property.typeConstraint)' for property '$($Property.name)'." }
    }
}

$builder = New-Object -TypeName System.Text.StringBuilder
$null = $builder.AppendLine('Configuration DscBenchConfig')
$null = $builder.AppendLine('{')
$null = $builder.AppendLine("    Import-DscResource -ModuleName '$ModuleName'")
$null = $builder.AppendLine('')
$null = $builder.AppendLine('    Node localhost')
$null = $builder.AppendLine('    {')

for ($i = 1; $i -le $InstanceCount; $i++)
{
    $entry = $chosen[($i - 1) % $chosen.Count]
    $keywordName = $entry.Keyword.keyword
    $null = $builder.AppendLine("        $keywordName Instance$i")
    $null = $builder.AppendLine('        {')
    $sortedRequired = @($entry.Required | Sort-Object -Property @{ Expression = { -not $_.isKey } }, @{ Expression = { $_.name } })
    foreach ($property in $sortedRequired)
    {
        $literal = Get-PropertyLiteral -Property $property -InstanceNumber $i
        $null = $builder.AppendLine("            $($property.name) = $literal")
    }
    $null = $builder.AppendLine('        }')
    if ($i -lt $InstanceCount) { $null = $builder.AppendLine('') }
}

$null = $builder.AppendLine('    }')
$null = $builder.AppendLine('}')

$resolvedOutput = $OutputPath
if (-not [System.IO.Path]::IsPathRooted($resolvedOutput))
{
    $resolvedOutput = Join-Path -Path (Get-Location).ProviderPath -ChildPath $resolvedOutput
}
$outputDirectory = Split-Path -Path $resolvedOutput -Parent
if ($outputDirectory -and -not (Test-Path -Path $outputDirectory))
{
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
}
[System.IO.File]::WriteAllText($resolvedOutput, $builder.ToString(), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

$meta = @{
    configurationName = 'DscBenchConfig'
    moduleName        = $ModuleName
    instanceCount     = $InstanceCount
    resourceSpread    = $chosen.Count
    keywords          = @($chosen | ForEach-Object { $_.Keyword.keyword })
}
[System.IO.File]::WriteAllText($resolvedOutput + '.meta.json', (ConvertTo-Json -InputObject $meta), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

[PSCustomObject]@{
    Path              = $resolvedOutput
    MetaPath          = $resolvedOutput + '.meta.json'
    ConfigurationName = 'DscBenchConfig'
    ModuleName        = $ModuleName
    Keywords          = @($chosen | ForEach-Object { $_.Keyword.keyword })
    InstanceCount     = $InstanceCount
}
