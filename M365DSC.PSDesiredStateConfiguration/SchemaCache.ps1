# Line based cache. Line 1 holds the header with the keyword index, line 2 the source file
# list, every later line one keyword.

$script:SchemaCacheFormatVersion = 2

function Get-DscSchemaCacheUserPath
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $ModuleName,

        [Parameter(Mandatory)]
        [System.Version]
        $ModuleVersion,

        [Parameter(Mandatory)]
        [System.String]
        $Fingerprint
    )

    $root = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'M365DSC.PSDesiredStateConfiguration\SchemaCache'
    $safeFingerprint = $Fingerprint.Replace(':', '_')
    Join-Path $root "${ModuleName}_${ModuleVersion}_${safeFingerprint}.json"
}

function ConvertTo-DscKeywordSchemaObject
{
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.DynamicKeyword]
        $Keyword
    )

    $properties = @{}
    foreach ($item in $Keyword.Properties.GetEnumerator())
    {
        $property = $item.Value
        $valueMap = @()
        if ($property.ValueMap)
        {
            foreach ($entry in $property.ValueMap.GetEnumerator())
            {
                $valueMap += @{ key = $entry.Key; value = $entry.Value }
            }
        }
        $properties[$item.Key] = @{
            name           = $property.Name
            typeConstraint = $property.TypeConstraint
            mandatory      = $property.Mandatory
            isKey          = $property.IsKey
            attributes     = @($property.Attributes)
            values         = @($property.Values)
            valueMap       = $valueMap
        }
    }

    @{
        keyword                   = $Keyword.Keyword
        resourceName              = $Keyword.ResourceName
        implementingModule        = $Keyword.ImplementingModule
        implementingModuleVersion = if ($Keyword.ImplementingModuleVersion) { $Keyword.ImplementingModuleVersion.ToString() } else { $null }
        nameMode                  = $Keyword.NameMode.ToString()
        bodyMode                  = $Keyword.BodyMode.ToString()
        directCall                = $Keyword.DirectCall
        metaStatement             = $Keyword.MetaStatement
        properties                = $properties
    }
}

function ConvertFrom-DscKeywordSchemaObject
{
    [OutputType([System.Management.Automation.Language.DynamicKeyword])]
    param (
        [Parameter(Mandatory)]
        $SchemaObject
    )

    $keyword = New-Object -TypeName System.Management.Automation.Language.DynamicKeyword
    $keyword.Keyword = $SchemaObject.keyword
    $keyword.ResourceName = $SchemaObject.resourceName
    $keyword.ImplementingModule = $SchemaObject.implementingModule
    if ($SchemaObject.implementingModuleVersion)
    {
        $keyword.ImplementingModuleVersion = [System.Version]$SchemaObject.implementingModuleVersion
    }
    $keyword.NameMode = [System.Management.Automation.Language.DynamicKeywordNameMode]$SchemaObject.nameMode
    $keyword.BodyMode = [System.Management.Automation.Language.DynamicKeywordBodyMode]$SchemaObject.bodyMode
    $keyword.DirectCall = [bool]$SchemaObject.directCall
    $keyword.MetaStatement = [bool]$SchemaObject.metaStatement

    foreach ($item in $SchemaObject.properties.PSObject.Properties)
    {
        $source = $item.Value
        $property = New-Object -TypeName System.Management.Automation.Language.DynamicKeywordProperty
        $property.Name = $source.name
        $property.TypeConstraint = $source.typeConstraint
        $property.Mandatory = [bool]$source.mandatory
        $property.IsKey = [bool]$source.isKey
        foreach ($attribute in @($source.attributes)) { if ($null -ne $attribute) { $property.Attributes.Add($attribute) } }
        foreach ($value in @($source.values)) { if ($null -ne $value) { $property.Values.Add($value) } }
        foreach ($mapEntry in @($source.valueMap))
        {
            if ($null -ne $mapEntry)
            {
                $property.ValueMap[[System.String]$mapEntry.key] = $mapEntry.value
            }
        }
        $keyword.Properties.Add($item.Name, $property)
    }

    $keyword
}

function Get-DscModuleSourceEntry
{
    [OutputType([System.Object[]])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $ModuleBase
    )

    $entries = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    foreach ($pattern in '*.psm1', '*.psd1', '*.mof')
    {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($ModuleBase, $pattern, [System.IO.SearchOption]::AllDirectories))
        {
            $entries.Add([PSCustomObject]@{
                    Path   = $file.Substring($ModuleBase.Length).TrimStart('\', '/')
                    Length = [System.IO.FileInfo]::new($file).Length
                })
        }
    }
    @($entries | Sort-Object -Property Path)
}

function ConvertTo-DscSourceFingerprint
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Object[]]
        $Entry
    )

    $total = [long]0
    $builder = New-Object -TypeName System.Text.StringBuilder
    foreach ($item in $Entry)
    {
        $total += [long]$item.Length
        $null = $builder.Append($item.Path.ToLowerInvariant()).Append('|').Append([System.String]$item.Length).Append("`n")
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
    }
    finally
    {
        $sha.Dispose()
    }
    $hex = [System.BitConverter]::ToString($hash, 0, 8).Replace('-', '').ToLowerInvariant()
    '{0}:{1}:{2}' -f $Entry.Count, $total, $hex
}

function Read-DscSchemaCacheFile
{
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Path
    )

    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0)
    {
        throw "Schema cache '$Path' is empty."
    }
    $header = ConvertFrom-Json -InputObject $lines[0]
    if ($null -eq $header.formatVersion -or $null -eq $header.module)
    {
        throw "Schema cache '$Path' has no header."
    }
    if ($header.formatVersion -eq $script:SchemaCacheFormatVersion -and $lines.Count -lt 2)
    {
        throw "Schema cache '$Path' is truncated."
    }
    [PSCustomObject]@{
        Path          = $Path
        formatVersion = $header.formatVersion
        generator     = $header.generator
        module        = $header.module
        index         = $header.index
        keywordCount  = $header.keywordCount
        resourceCount = $header.resourceCount
        Lines         = $lines
    }
}

function Get-DscSchemaCacheSourceList
{
    param (
        [Parameter(Mandatory)]
        $Cache
    )

    ConvertFrom-Json -InputObject $Cache.Lines[1]
}

function Get-DscSchemaCacheKeyword
{
    [OutputType([System.Management.Automation.Language.DynamicKeyword])]
    param (
        [Parameter(Mandatory)]
        $Cache,

        [Parameter(Mandatory)]
        [System.String]
        $Name
    )

    $entry = $Cache.index.PSObject.Properties[$Name]
    if ($null -eq $entry)
    {
        return $null
    }
    ConvertFrom-DscKeywordSchemaObject -SchemaObject (ConvertFrom-Json -InputObject $Cache.Lines[[int]$entry.Value])
}

function Get-DscSchemaCacheKeywordName
{
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory)]
        $Cache
    )

    @($Cache.index.PSObject.Properties | ForEach-Object { $_.Name })
}

function Export-DscSchemaCache
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [System.String]
        $ModuleName,

        [Parameter(ParameterSetName = 'ByName')]
        [System.Version]
        $RequiredVersion,

        [Parameter(Mandatory, ParameterSetName = 'ByModuleInfo')]
        [System.Management.Automation.PSModuleInfo]
        $Module,

        [System.String]
        $OutputPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByName')
    {
        $candidates = Get-Module -ListAvailable -Name $ModuleName | Sort-Object -Property Version -Descending
        if ($RequiredVersion)
        {
            $candidates = $candidates | Where-Object -Property Version -EQ $RequiredVersion
        }
        $Module = $candidates | Select-Object -First 1
        if (-not $Module)
        {
            throw "Module '$ModuleName' $(if ($RequiredVersion) { "version $RequiredVersion " })was not found."
        }
    }

    Reset-DscKeywordState
    $defaultFunctions = New-Object -TypeName 'System.Collections.Generic.Dictionary[System.String, ScriptBlock]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::LoadDefaultCimKeywords($defaultFunctions)
    $defaultKeywordNames = New-Object -TypeName 'System.Collections.Generic.HashSet[System.String]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($keyword in [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetCachedKeywords())
    {
        $null = $defaultKeywordNames.Add($keyword.Keyword)
    }

    $resources = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
    $resources.Add('*')
    $throwaway = New-Object -TypeName 'System.Collections.Generic.Dictionary[System.String, ScriptBlock]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $null = [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ImportClassResourcesFromModule($Module, $resources, $throwaway)

    $dscResourcesPath = Join-Path $Module.ModuleBase 'DscResources'
    if (Test-Path $dscResourcesPath)
    {
        foreach ($resourceDirectory in [System.IO.Directory]::EnumerateDirectories($dscResourcesPath))
        {
            $resourceName = Split-Path $resourceDirectory -Leaf
            if (-not (Test-Path (Join-Path $resourceDirectory "$resourceName.schema.mof")))
            {
                continue
            }
            $schemaFilePath = $null
            $keywordErrors = New-Object -TypeName 'System.Collections.ObjectModel.Collection[System.Exception]'
            $null = [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ImportCimKeywordsFromModule(
                $Module, $resourceName, [ref] $schemaFilePath, $throwaway, $keywordErrors)
            foreach ($keywordError in $keywordErrors)
            {
                Write-Warning -Message "Schema of resource '$resourceName' was not imported: $($keywordError.Message)"
            }
        }
    }

    $keywords = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    foreach ($keyword in [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetCachedKeywords())
    {
        if (-not $defaultKeywordNames.Contains($keyword.Keyword))
        {
            $keywords.Add((ConvertTo-DscKeywordSchemaObject -Keyword $keyword))
        }
    }

    Reset-DscKeywordState

    $entries = Get-DscModuleSourceEntry -ModuleBase $Module.ModuleBase
    $fingerprint = ConvertTo-DscSourceFingerprint -Entry $entries
    $sources = [ordered]@{}
    foreach ($item in $entries)
    {
        $sources[$item.Path] = @{
            length = $item.Length
            sha256 = (Get-FileHash -Path (Join-Path $Module.ModuleBase $item.Path) -Algorithm SHA256).Hash
        }
    }

    $index = [ordered]@{}
    $resourceCount = 0
    for ($i = 0; $i -lt $keywords.Count; $i++)
    {
        $index[[System.String]$keywords[$i].keyword] = $i + 2
        if ($keywords[$i].nameMode -eq 'NameRequired')
        {
            $resourceCount++
        }
    }

    $header = [ordered]@{
        formatVersion = $script:SchemaCacheFormatVersion
        generator     = @{
            psdscVersion = $ExecutionContext.SessionState.Module.Version.ToString()
            psVersion    = $PSVersionTable.PSVersion.ToString()
        }
        module        = @{
            name        = $Module.Name
            version     = $Module.Version.ToString()
            fingerprint = $fingerprint
        }
        resourceCount = $resourceCount
        keywordCount  = $keywords.Count
        index         = $index
    }

    if (-not $OutputPath)
    {
        $OutputPath = Join-Path $Module.ModuleBase 'DscSchemaCache.json'
    }
    $directory = Split-Path $OutputPath -Parent
    if ($directory -and -not (Test-Path $directory))
    {
        $null = New-Item -ItemType Directory -Force -Path $directory
    }

    $lines = New-Object -TypeName 'System.Collections.Generic.List[System.String]'
    $lines.Add((ConvertTo-Json -InputObject $header -Depth 6 -Compress))
    $lines.Add((ConvertTo-Json -InputObject $sources -Depth 4 -Compress))
    foreach ($keyword in $keywords)
    {
        $lines.Add((ConvertTo-Json -InputObject $keyword -Depth 12 -Compress))
    }
    [System.IO.File]::WriteAllLines($OutputPath, $lines, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose -Message "Schema cache for $($Module.Name) $($Module.Version) written to $OutputPath ($($keywords.Count) keywords)."
    [PSCustomObject]@{
        ModuleName    = $Module.Name
        ModuleVersion = $Module.Version
        ResourceCount = $resourceCount
        KeywordCount  = $keywords.Count
        Fingerprint   = $fingerprint
        Path          = $OutputPath
    }
}
Export-ModuleMember -Function Export-DscSchemaCache

function Test-DscSchemaCache
{
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $ModulePath,

        [Parameter(Mandatory)]
        [System.String]
        $CachePath,

        [switch]
        $Detailed
    )

    if (-not (Test-Path $CachePath))
    {
        Write-Warning -Message "Schema cache '$CachePath' does not exist."
        return $false
    }

    $manifestPath = if ([System.IO.Path]::GetExtension($ModulePath) -eq '.psd1') { $ModulePath } else { Get-ChildItem -Path $ModulePath -Filter '*.psd1' | Select-Object -First 1 -ExpandProperty FullName }
    $moduleBase = Split-Path $manifestPath -Parent
    $manifest = Import-PowerShellDataFile -Path $manifestPath
    try
    {
        $cache = Read-DscSchemaCacheFile -Path $CachePath
    }
    catch
    {
        Write-Warning -Message "Schema cache '$CachePath' could not be read: $($_.Exception.Message)"
        return $false
    }

    $valid = $true
    if ($cache.formatVersion -ne $script:SchemaCacheFormatVersion)
    {
        Write-Warning -Message "Cache format version $($cache.formatVersion) is not the supported version $script:SchemaCacheFormatVersion."
        return $false
    }
    if ($cache.module.version -ne $manifest.ModuleVersion)
    {
        Write-Warning -Message "Cache is for module version $($cache.module.version); manifest declares $($manifest.ModuleVersion)."
        $valid = $false
    }

    $sources = Get-DscSchemaCacheSourceList -Cache $cache
    foreach ($entry in $sources.PSObject.Properties)
    {
        $file = Join-Path $moduleBase $entry.Name
        if (-not (Test-Path $file))
        {
            Write-Warning -Message "File in cache no longer exists: $($entry.Name)"
            $valid = $false
        }
        elseif ($Detailed -and (Get-FileHash -Path $file -Algorithm SHA256).Hash -ne $entry.Value.sha256)
        {
            Write-Warning -Message "File changed since cache generation: $($entry.Name)"
            $valid = $false
        }
    }

    $valid
}
Export-ModuleMember -Function Test-DscSchemaCache

# A file that appears next to the module later must not invalidate the cache. Only the
# recorded files count.
function Get-DscSchemaCacheSourceFingerprint
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $ModuleBase,

        [Parameter(Mandatory)]
        $Cache
    )

    $sources = Get-DscSchemaCacheSourceList -Cache $Cache
    $entries = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    foreach ($entry in $sources.PSObject.Properties)
    {
        $file = Join-Path $ModuleBase $entry.Name
        if (-not [System.IO.File]::Exists($file))
        {
            return $null
        }
        $entries.Add([PSCustomObject]@{ Path = $entry.Name; Length = [System.IO.FileInfo]::new($file).Length })
    }
    if ($entries.Count -eq 0)
    {
        return $null
    }
    ConvertTo-DscSourceFingerprint -Entry @($entries | Sort-Object -Property Path)
}

function Get-DscSchemaCache
{
    param (
        [Parameter(Mandatory)]
        $Module,

        [string[]]
        $SchemaCachePath
    )

    $fingerprint = Get-DscModuleFingerprint -Module $Module
    $candidates = @()
    if ($SchemaCachePath)
    {
        $candidates += $SchemaCachePath
    }
    $candidates += (Join-Path $Module.ModuleBase 'DscSchemaCache.json')
    $candidates += Get-DscSchemaCacheUserPath -ModuleName $Module.Name -ModuleVersion $Module.Version -Fingerprint $fingerprint

    foreach ($candidate in $candidates)
    {
        if (-not (Test-Path $candidate))
        {
            continue
        }
        try
        {
            $cache = Read-DscSchemaCacheFile -Path $candidate
        }
        catch
        {
            Write-Warning -Message "Schema cache '$candidate' could not be read: $($_.Exception.Message)"
            continue
        }
        if ($cache.formatVersion -ne $script:SchemaCacheFormatVersion)
        {
            Write-Verbose -Message "Schema cache '$candidate' has format version $($cache.formatVersion), expected $script:SchemaCacheFormatVersion."
            continue
        }
        if ($cache.module.name -ne $Module.Name -or $cache.module.version -ne $Module.Version.ToString())
        {
            Write-Warning -Message "Schema cache '$candidate' is for $($cache.module.name) $($cache.module.version), not $($Module.Name) $($Module.Version)."
            continue
        }
        if ($cache.module.fingerprint -ne $fingerprint)
        {
            $recorded = Get-DscSchemaCacheSourceFingerprint -ModuleBase $Module.ModuleBase -Cache $cache
            if ($cache.module.fingerprint -ne $recorded)
            {
                Write-Verbose -Message "Schema cache '$candidate' is stale (module files changed)."
                continue
            }
        }
        return $cache
    }

    $null
}

function New-DscSchemaCacheForModule
{
    param (
        [Parameter(Mandatory)]
        $Module
    )

    $moduleInfo = $Module
    if ($Module -isnot [System.Management.Automation.PSModuleInfo])
    {
        $moduleInfo = Get-Module -ListAvailable -Name $Module.Path | Select-Object -First 1
        if ($null -eq $moduleInfo)
        {
            throw "Module manifest '$($Module.Path)' could not be loaded for schema discovery."
        }
    }
    $fingerprint = Get-DscModuleFingerprint -Module $moduleInfo
    $userPath = Get-DscSchemaCacheUserPath -ModuleName $moduleInfo.Name -ModuleVersion $moduleInfo.Version -Fingerprint $fingerprint
    Write-Verbose -Message "Generating schema cache for $($moduleInfo.Name) $($moduleInfo.Version) (one-time operation)."
    $null = Export-DscSchemaCache -Module $moduleInfo -OutputPath $userPath
    Get-DscSchemaCache -Module $moduleInfo -SchemaCachePath $userPath
}
