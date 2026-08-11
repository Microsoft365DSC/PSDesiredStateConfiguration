# Persistent DSC schema cache: serializes DynamicKeyword definitions of a module
# to JSON so the fast host can register them without any module parsing.

$script:SchemaCacheFormatVersion = 1

function Get-DscSchemaCacheUserPath
{
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]
        $ModuleName,

        [Parameter(Mandatory)]
        [version]
        $ModuleVersion,

        [Parameter(Mandatory)]
        [string]
        $Fingerprint
    )

    $root = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'PSDesiredStateConfiguration\SchemaCache'
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
        $keyword.ImplementingModuleVersion = [version]$SchemaObject.implementingModuleVersion
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
                $property.ValueMap[[string]$mapEntry.key] = $mapEntry.value
            }
        }
        $keyword.Properties.Add($item.Name, $property)
    }

    $keyword
}

function Export-DscSchemaCache
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ParameterSetName = 'ByName', Position = 0)]
        [string]
        $ModuleName,

        [Parameter(ParameterSetName = 'ByName')]
        [version]
        $RequiredVersion,

        [Parameter(Mandatory, ParameterSetName = 'ByModuleInfo')]
        [System.Management.Automation.PSModuleInfo]
        $Module,

        [string]
        $OutputPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByName')
    {
        $candidates = Get-Module -ListAvailable -Name $ModuleName | Sort-Object -Property Version -Descending
        if ($RequiredVersion)
        {
            $candidates = $candidates | Where-Object { $_.Version -eq $RequiredVersion }
        }
        $Module = $candidates | Select-Object -First 1
        if (-not $Module)
        {
            throw "Module '$ModuleName' $(if ($RequiredVersion) { "version $RequiredVersion " })was not found."
        }
    }

    Clear-DscKeywordCache
    $defaultFunctions = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,scriptblock]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::LoadDefaultCimKeywords($defaultFunctions)
    $defaultKeywordNames = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($keyword in [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetCachedKeywords())
    {
        $null = $defaultKeywordNames.Add($keyword.Keyword)
    }

    $resources = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $resources.Add('*')
    $throwaway = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,scriptblock]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $null = [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ImportClassResourcesFromModule($Module, $resources, $throwaway)

    $keywords = @()
    foreach ($keyword in [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetCachedKeywords())
    {
        if (-not $defaultKeywordNames.Contains($keyword.Keyword))
        {
            $keywords += ConvertTo-DscKeywordSchemaObject -Keyword $keyword
        }
    }

    $fingerprint = Get-DscModuleFingerprint -Module $Module
    $sourceHash = @{}
    foreach ($pattern in '*.psm1', '*.psd1', '*.mof')
    {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($Module.ModuleBase, $pattern, [System.IO.SearchOption]::AllDirectories))
        {
            $relative = $file.Substring($Module.ModuleBase.Length).TrimStart('\', '/')
            $sourceHash[$relative] = (Get-FileHash -Path $file -Algorithm SHA256).Hash
        }
    }

    $cache = @{
        formatVersion = $script:SchemaCacheFormatVersion
        generator     = @{
            psdscVersion = (Get-Module PSDesiredStateConfiguration | Select-Object -First 1).Version.ToString()
            psVersion    = $PSVersionTable.PSVersion.ToString()
        }
        module        = @{
            name        = $Module.Name
            version     = $Module.Version.ToString()
            fingerprint = $fingerprint
            sourceHash  = $sourceHash
        }
        keywords      = $keywords
    }

    Clear-DscKeywordCache

    if (-not $OutputPath)
    {
        $OutputPath = Join-Path $Module.ModuleBase 'DscSchemaCache.json'
    }
    $directory = Split-Path $OutputPath -Parent
    if ($directory -and -not (Test-Path $directory))
    {
        $null = New-Item -ItemType Directory -Force -Path $directory
    }
    $json = ConvertTo-Json -InputObject $cache -Depth 12 -Compress
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose -Message "Schema cache for $($Module.Name) $($Module.Version) written to $OutputPath ($($keywords.Count) keywords)."
    [PSCustomObject]@{
        ModuleName    = $Module.Name
        ModuleVersion = $Module.Version
        ResourceCount = @($keywords | Where-Object { $_.nameMode -eq 'NameRequired' }).Count
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
        [string]
        $ModulePath,

        [Parameter(Mandatory)]
        [string]
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
    $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($CachePath))

    $valid = $true
    if ($cache.formatVersion -gt $script:SchemaCacheFormatVersion)
    {
        Write-Warning -Message "Cache format version $($cache.formatVersion) is newer than supported ($script:SchemaCacheFormatVersion)."
        $valid = $false
    }
    if ($cache.module.version -ne $manifest.ModuleVersion)
    {
        Write-Warning -Message "Cache is for module version $($cache.module.version); manifest declares $($manifest.ModuleVersion)."
        $valid = $false
    }

    foreach ($entry in $cache.module.sourceHash.PSObject.Properties)
    {
        $file = Join-Path $moduleBase $entry.Name
        if (-not (Test-Path $file))
        {
            Write-Warning -Message "File in cache no longer exists: $($entry.Name)"
            $valid = $false
        }
        elseif ($Detailed -and (Get-FileHash -Path $file -Algorithm SHA256).Hash -ne $entry.Value)
        {
            Write-Warning -Message "File changed since cache generation: $($entry.Name)"
            $valid = $false
        }
    }

    $valid
}
Export-ModuleMember -Function Test-DscSchemaCache

function Get-DscSchemaCache
{
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo]
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
            $cache = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($candidate))
        }
        catch
        {
            Write-Warning -Message "Schema cache '$candidate' could not be parsed: $($_.Exception.Message)"
            continue
        }
        if ($cache.formatVersion -gt $script:SchemaCacheFormatVersion)
        {
            Write-Warning -Message "Schema cache '$candidate' has unsupported format version $($cache.formatVersion)."
            continue
        }
        if ($cache.module.name -ne $Module.Name -or $cache.module.version -ne $Module.Version.ToString())
        {
            Write-Warning -Message "Schema cache '$candidate' is for $($cache.module.name) $($cache.module.version), not $($Module.Name) $($Module.Version)."
            continue
        }
        if ($cache.module.fingerprint -ne $fingerprint)
        {
            Write-Warning -Message "Schema cache '$candidate' is stale (module files changed)."
            continue
        }
        return $cache
    }

    $null
}

function New-DscSchemaCacheForModule
{
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo]
        $Module
    )

    $fingerprint = Get-DscModuleFingerprint -Module $Module
    $userPath = Get-DscSchemaCacheUserPath -ModuleName $Module.Name -ModuleVersion $Module.Version -Fingerprint $fingerprint
    Write-Verbose -Message "Generating schema cache for $($Module.Name) $($Module.Version) (one-time operation)."
    $null = Export-DscSchemaCache -Module $Module -OutputPath $userPath
    Get-DscSchemaCache -Module $Module -SchemaCachePath $userPath
}
