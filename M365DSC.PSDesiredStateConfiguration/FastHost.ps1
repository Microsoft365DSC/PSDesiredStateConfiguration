# Fast compilation host: compiles a configuration script without triggering the
# engine's parse-time resource import by stripping Import-DscResource statements
# and registering keywords from a persistent schema cache instead.

$script:FastHostAdapterText = @'
$__fhKeywordName = $MyInvocation.InvocationName
if ($__fhKeywordName.Contains('\'))
{
    $__fhKeywordName = $__fhKeywordName.Substring($__fhKeywordName.LastIndexOf('\') + 1)
}
$__fhKeyword = Get-FastHostKeyword -Name $__fhKeywordName
if ($null -eq $__fhKeyword)
{
    throw "The DSC resource '$__fhKeywordName' is not present in the schema cache."
}
if ($args.Count -lt 1)
{
    throw "Resource '$__fhKeywordName': expected a { } property block as the last argument."
}
$__fhBody = $args[$args.Count - 1]
$__fhName = ''
if ($__fhKeyword.NameMode -eq [System.Management.Automation.Language.DynamicKeywordNameMode]::NameRequired)
{
    if ($args.Count -lt 2 -or $args[0] -isnot [System.String])
    {
        throw "Resource '$__fhKeywordName': expected '$__fhKeywordName <instance name> { ... }'."
    }
    $__fhName = $args[0]
}
elseif ($args.Count -ge 2 -and $args[0] -is [System.String])
{
    $__fhName = $args[0]
}
if ($__fhBody -isnot [hashtable])
{
    throw "Resource '$__fhKeywordName': the property block reached the adapter as $($__fhBody.GetType().Name) instead of a hashtable. ConvertTo-FastHostCompileText did not rewrite it."
}
$__fhValue = $__fhBody
$__fhFile = $MyInvocation.ScriptName
if ([System.String]::IsNullOrEmpty($__fhFile))
{
    # The body runs from a scriptblock built out of the stripped text, so it carries no
    # file. Use the path the compile was started from, to keep SourceInfo identical to
    # what the standard path emits.
    $__fhFile = Get-FastHostScriptPath
}
$__fhSource = "$__fhFile::$($MyInvocation.ScriptLineNumber)::$($MyInvocation.OffsetInLine)::$__fhKeywordName"
& (Get-CimKeywordImplementationFunction) -KeywordData $__fhKeyword -Name $__fhName -Value $__fhValue -SourceMetadata $__fhSource
'@

function Get-FastHostScriptPath
{
    [OutputType([System.String])]
    param()

    $script:FastHostScriptPath
}

# The cache stays as text lines until a compile asks for a keyword.
function Get-FastHostKeyword
{
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Name
    )

    if ($script:FastHostKeywords)
    {
        $keyword = $script:FastHostKeywords[$Name]
        if ($null -ne $keyword)
        {
            return $keyword
        }
    }

    if ($script:FastHostKeywordSource)
    {
        foreach ($cache in $script:FastHostKeywordSource)
        {
            $keyword = Get-DscSchemaCacheKeyword -Cache $cache -Name $Name
            if ($null -ne $keyword)
            {
                $script:FastHostKeywords[$keyword.Keyword] = $keyword
                return $keyword
            }
        }
    }

    $null
}

function Get-FastHostKeywordName
{
    [OutputType([System.Collections.Generic.HashSet[System.String]])]
    param()

    $names = New-Object -TypeName 'System.Collections.Generic.HashSet[System.String]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:FastHostKeywords)
    {
        foreach ($key in $script:FastHostKeywords.Keys)
        {
            $null = $names.Add($key)
        }
    }
    if ($script:FastHostKeywordSource)
    {
        foreach ($cache in $script:FastHostKeywordSource)
        {
            foreach ($name in (Get-DscSchemaCacheKeywordName -Cache $cache))
            {
                $null = $names.Add($name)
            }
        }
    }
    , $names
}

function Get-FastHostBodyScriptBlock
{
    [OutputType([ScriptBlock])]
    param (
        [Parameter(Mandatory)]
        [ScriptBlock]
        $Body
    )

    $text = $Body.Ast.Extent.Text
    $cached = $script:FastHostBodyCache[$text]
    if ($null -eq $cached)
    {
        $inner = $text.Substring(1, $text.Length - 2)
        $cached = [ScriptBlock]::Create('@{' + $inner + '}')
        $script:FastHostBodyCache[$text] = $cached
    }
    $cached
}

function Register-DscSchemaCache
{
    param (
        [Parameter(Mandatory)]
        $Cache
    )

    if ($null -eq $script:FastHostKeywords)
    {
        $script:FastHostKeywords = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,System.Management.Automation.Language.DynamicKeyword]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($null -eq $script:FastHostAdapters)
    {
        $script:FastHostAdapters = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,scriptblock]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($null -eq $script:FastHostKeywordSource)
    {
        $script:FastHostKeywordSource = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    }
    $script:FastHostKeywordSource.Add($Cache)

    $adapter = [ScriptBlock]::Create($script:FastHostAdapterText)
    $moduleName = [System.String]$Cache.module.name
    foreach ($name in (Get-DscSchemaCacheKeywordName -Cache $Cache))
    {
        $script:FastHostAdapters[$name] = $adapter
        if ($moduleName)
        {
            $script:FastHostAdapters["$moduleName\$name"] = $adapter
        }
    }
}

# Returns the keyword a next-line brace would belong to, or $null. There are two possible ways
# for such a keyword to appear:
#
#   KeywordName [InstanceName]        - a resource statement
#   PropertyName = KeywordName        - a nested CIM instance inside a resource body
#
# The second shape is not an assignment. It is inside a configuration body, and 'PropertyName' is a
# bare word, so the parser produces one CommandAst whose elements are the property name,
# a literal '=' and the keyword.
function Get-FastHostMergeCandidateKeyword
{
    [OutputType([System.Object])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.StatementAst]
        $Statement
    )

    $pipeline = $Statement -as [System.Management.Automation.Language.PipelineAst]
    if ($null -eq $pipeline)
    {
        $assignment = $Statement -as [System.Management.Automation.Language.AssignmentStatementAst]
        if ($null -eq $assignment)
        {
            return $null
        }

        $pipeline = $assignment.Right -as [System.Management.Automation.Language.PipelineAst]
    }

    if ($null -eq $pipeline -or $pipeline.PipelineElements.Count -ne 1)
    {
        return $null
    }

    $command = $pipeline.PipelineElements[0] -as [System.Management.Automation.Language.CommandAst]
    if ($null -eq $command)
    {
        return $null
    }

    $elements = $command.CommandElements
    if ($elements.Count -le 2)
    {
        return [PSCustomObject]@{
            Name      = $command.GetCommandName()
            EndOffset = $command.Extent.EndOffset
        }
    }

    # 'PropertyName = KeywordName [InstanceName]'
    if ($elements.Count -le 4 -and $elements[1].Extent.Text -eq '=')
    {
        $keywordElement = $elements[2] -as [System.Management.Automation.Language.StringConstantExpressionAst]
        if ($null -eq $keywordElement)
        {
            return $null
        }

        return [PSCustomObject]@{
            Name      = $keywordElement.Value
            EndOffset = $command.Extent.EndOffset
        }
    }

    return $null
}

function Get-FastHostBodyKeywordName
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.CommandAst]
        $Command
    )

    $elements = $Command.CommandElements
    if ($elements.Count -ge 3 -and $elements[1].Extent.Text -eq '=')
    {
        $keyword = $elements[2] -as [System.Management.Automation.Language.StringConstantExpressionAst]
        if ($null -eq $keyword)
        {
            return $null
        }

        return $keyword.Value
    }

    return $Command.GetCommandName()
}

# A parsed configuration statement imports its resource modules. Masking the word keeps the
# parser away from that, and the same-length replacement keeps every extent offset valid for
# the original text.
function Get-FastHostMaskedAst
{
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text
    )

    $masked = [regex]::Replace($Text, '(?i)\bConfiguration\b', 'C0nfiguration')
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($masked, [ref]$tokens, [ref]$parseErrors)
}

function Invoke-FastHostTextEdit
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [System.String]
        $Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Edit
    )

    if ($Edit.Count -eq 0)
    {
        return $Text
    }

    $ordered = @($Edit | Sort-Object -Property Start, Length)
    $builder = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($Text.Length + $ordered.Count * 2)
    $position = 0
    foreach ($item in $ordered)
    {
        if ($item.Start -lt $position)
        {
            throw "Overlapping text edits at offset $($item.Start)."
        }
        $null = $builder.Append($Text.Substring($position, $item.Start - $position))
        $null = $builder.Append($item.Text)
        $position = $item.Start + $item.Length
    }
    $null = $builder.Append($Text.Substring($position))
    $builder.ToString()
}

function ConvertTo-FastHostCompileText
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text,

        [System.Management.Automation.Language.ScriptBlockAst]
        $Ast,

        [AllowEmptyCollection()]
        $ImportStatement = @(),

        [AllowEmptyCollection()]
        $KeywordNames = @(),

        [switch]
        $Merge,

        [switch]
        $Convert
    )

    if ($null -eq $Ast)
    {
        $Ast = Get-FastHostMaskedAst -Text $Text
    }

    $names = $KeywordNames -as [System.Collections.Generic.HashSet[System.String]]
    if ($null -eq $names)
    {
        $names = New-Object -TypeName 'System.Collections.Generic.HashSet[System.String]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($KeywordNames)) { $null = $names.Add([System.String]$name) }
    }

    $edits = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    foreach ($statement in @($ImportStatement))
    {
        $edits.Add([PSCustomObject]@{ Start = $statement.Extent.StartOffset; Length = $statement.Extent.EndOffset - $statement.Extent.StartOffset; Text = '' })
    }

    if ($names.Count -eq 0 -or -not ($Merge -or $Convert))
    {
        return Invoke-FastHostTextEdit -Text $Text -Edit $edits
    }

    $bodyStarts = New-Object -TypeName 'System.Collections.Generic.HashSet[int]'

    # With the keyword unknown to the parser, a next-line brace parses as a separate scriptblock
    # statement and the engine rejects the resource as undefined.
    if ($Merge)
    {
        $blocks = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StatementBlockAst] -or $args[0] -is [System.Management.Automation.Language.NamedBlockAst] }, $true)
        foreach ($block in $blocks)
        {
            $statements = $block.Statements
            for ($i = 0; $i -lt $statements.Count - 1; $i++)
            {
                $candidate = Get-FastHostMergeCandidateKeyword -Statement $statements[$i]
                if ($null -eq $candidate -or -not $candidate.Name -or -not $names.Contains($candidate.Name))
                {
                    continue
                }
                $second = $statements[$i + 1]
                if ($second -isnot [System.Management.Automation.Language.PipelineAst] -or $second.PipelineElements.Count -ne 1)
                {
                    continue
                }
                $expression = $second.PipelineElements[0] -as [System.Management.Automation.Language.CommandExpressionAst]
                if ($null -eq $expression -or
                    ($expression.Expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                     $expression.Expression -isnot [System.Management.Automation.Language.HashtableAst]))
                {
                    continue
                }
                $gapStart = $candidate.EndOffset
                $gapLength = $second.Extent.StartOffset - $gapStart
                if ($gapLength -gt 0)
                {
                    $edits.Add([PSCustomObject]@{ Start = $gapStart; Length = $gapLength; Text = ' ' })
                }
                if ($Convert -and $expression.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst])
                {
                    $offset = $second.Extent.StartOffset
                    if ($bodyStarts.Add($offset))
                    {
                        $prefix = if ($gapLength -gt 0 -or ($offset -gt 0 -and [char]::IsWhiteSpace($Text[$offset - 1]))) { '@' } else { ' @' }
                        $edits.Add([PSCustomObject]@{ Start = $offset; Length = 0; Text = $prefix })
                    }
                }
            }
        }
    }

    if ($Convert)
    {
        $commands = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands)
        {
            $elements = $command.CommandElements
            $body = $elements[$elements.Count - 1] -as [System.Management.Automation.Language.ScriptBlockExpressionAst]
            if ($null -eq $body)
            {
                continue
            }

            $name = Get-FastHostBodyKeywordName -Command $command
            if (-not $name -or -not $names.Contains($name))
            {
                continue
            }

            $offset = $body.Extent.StartOffset
            if ($bodyStarts.Add($offset))
            {
                # 'MSFT_Type @{' parses, 'MSFT_Type@{' does not
                # Keep a separator when the source had none
                $prefix = if ($offset -gt 0 -and -not [char]::IsWhiteSpace($Text[$offset - 1])) { ' @' } else { '@' }
                $edits.Add([PSCustomObject]@{ Start = $offset; Length = 0; Text = $prefix })
            }
        }
    }

    Invoke-FastHostTextEdit -Text $Text -Edit $edits
}

function Merge-FastHostResourceStatements
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text,

        [Parameter(Mandatory)]
        $KeywordNames
    )

    ConvertTo-FastHostCompileText -Text $Text -KeywordNames $KeywordNames -Merge
}

function Convert-FastHostBodyToHashtable
{
    [OutputType([System.String])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text,

        [Parameter(Mandatory)]
        $KeywordNames
    )

    ConvertTo-FastHostCompileText -Text $Text -KeywordNames $KeywordNames -Convert
}

function Get-StrippedConfigurationText
{
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text
    )

    $ast = Get-FastHostMaskedAst -Text $Text

    $configurationNames = @()
    $importStatements = @()
    $commands = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($command in $commands)
    {
        $commandName = $command.GetCommandName()
        if ($commandName -eq 'C0nfiguration')
        {
            foreach ($element in $command.CommandElements)
            {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $element.Value -ne 'C0nfiguration')
                {
                    $configurationNames += $element.Value
                    break
                }
            }
        }
        elseif ($commandName -eq 'Import-DscResource')
        {
            $importStatements += $command
        }
    }

    $moduleSpecs = @()
    foreach ($statement in $importStatements)
    {
        $names = @()
        $moduleNames = @()
        $moduleVersion = $null
        $currentParameter = 'Name'
        $positionalIndex = 0
        $supported = $true

        for ($i = 1; $i -lt $statement.CommandElements.Count; $i++)
        {
            $element = $statement.CommandElements[$i]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst])
            {
                $currentParameter = $element.ParameterName
                continue
            }

            $values = @()
            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst])
            {
                $values = @($element.Value)
            }
            elseif ($element -is [System.Management.Automation.Language.ConstantExpressionAst])
            {
                $values = @($element.Extent.Text)
            }
            elseif ($element -is [System.Management.Automation.Language.ArrayLiteralAst])
            {
                foreach ($arrayElement in $element.Elements)
                {
                    if ($arrayElement -is [System.Management.Automation.Language.StringConstantExpressionAst])
                    {
                        $values += $arrayElement.Value
                    }
                    else
                    {
                        $supported = $false
                    }
                }
            }
            else
            {
                $supported = $false
            }

            if (-not $supported)
            {
                break
            }

            $effectiveParameter = $currentParameter
            if ($currentParameter -eq 'Name' -and $element -eq $statement.CommandElements[$i] -and -not ($statement.CommandElements[$i - 1] -is [System.Management.Automation.Language.CommandParameterAst]))
            {
                $effectiveParameter = switch ($positionalIndex) { 0 { 'Name' } 1 { 'ModuleName' } 2 { 'ModuleVersion' } default { $null } }
                $positionalIndex++
            }

            switch ($effectiveParameter)
            {
                'Name' { $names += $values }
                'ModuleName' { $moduleNames += $values }
                'ModuleVersion' { $moduleVersion = [version]$values[0] }
                default { $supported = $false }
            }
            $currentParameter = 'Name'
        }

        if (-not $supported)
        {
            return [PSCustomObject]@{
                Supported          = $false
                Reason             = "Unsupported Import-DscResource form at line $($statement.Extent.StartLineNumber): only constant -Name/-ModuleName/-ModuleVersion values are supported."
                Text               = $null
                ModuleSpecs        = @()
                ConfigurationNames = @()
                Ast                = $null
                ImportStatements   = @()
            }
        }

        if ($moduleNames.Count -eq 0 -and $names.Count -gt 0)
        {
            return [PSCustomObject]@{
                Supported          = $false
                Reason             = "Import-DscResource at line $($statement.Extent.StartLineNumber) uses -Name without -ModuleName, which requires scanning all installed modules."
                Text               = $null
                ModuleSpecs        = @()
                ConfigurationNames = @()
                Ast                = $null
                ImportStatements   = @()
            }
        }

        foreach ($moduleName in $moduleNames)
        {
            $moduleSpecs += [PSCustomObject]@{
                ModuleName    = $moduleName
                ModuleVersion = $moduleVersion
                Resources     = if ($names.Count -gt 0) { $names } else { @('*') }
            }
        }
    }

    [PSCustomObject]@{
        Supported          = $true
        Reason             = $null
        Text               = ConvertTo-FastHostCompileText -Text $Text -Ast $ast -ImportStatement $importStatements
        ModuleSpecs        = $moduleSpecs
        ConfigurationNames = $configurationNames
        Ast                = $ast
        ImportStatements   = $importStatements
    }
}

# Get-Module -ListAvailable analyzes every nested module of a manifest and costs seconds for
# a large resource module. A manifest scan is enough for the cache lookup.
function Resolve-FastHostModule
{
    [OutputType([System.Object])]
    param (
        [Parameter(Mandatory)]
        [System.String]
        $ModuleName,

        [version]
        $ModuleVersion
    )

    $candidates = New-Object -TypeName 'System.Collections.Generic.List[System.Object]'
    foreach ($entry in ($env:PSModulePath -split [System.IO.Path]::PathSeparator))
    {
        if ([System.String]::IsNullOrWhiteSpace($entry))
        {
            continue
        }
        $moduleFolder = Join-Path -Path $entry -ChildPath $ModuleName
        if (-not [System.IO.Directory]::Exists($moduleFolder))
        {
            continue
        }
        $flat = Join-Path -Path $moduleFolder -ChildPath "$ModuleName.psd1"
        if ([System.IO.File]::Exists($flat))
        {
            $candidates.Add([PSCustomObject]@{ Path = $flat; FolderVersion = $null })
        }
        foreach ($versionFolder in [System.IO.Directory]::EnumerateDirectories($moduleFolder))
        {
            $manifest = Join-Path -Path $versionFolder -ChildPath "$ModuleName.psd1"
            if (-not [System.IO.File]::Exists($manifest))
            {
                continue
            }
            $folderVersion = $null
            $null = [version]::TryParse((Split-Path $versionFolder -Leaf), [ref]$folderVersion)
            $candidates.Add([PSCustomObject]@{ Path = $manifest; FolderVersion = $folderVersion })
        }
    }

    $best = $null
    foreach ($candidate in $candidates)
    {
        if ($ModuleVersion -and $candidate.FolderVersion -and $candidate.FolderVersion -ne $ModuleVersion)
        {
            continue
        }
        try
        {
            $data = Import-PowerShellDataFile -Path $candidate.Path -ErrorAction Stop
        }
        catch
        {
            continue
        }
        $version = $null
        if (-not [version]::TryParse([System.String]$data.ModuleVersion, [ref]$version))
        {
            continue
        }
        if ($ModuleVersion -and $version -ne $ModuleVersion)
        {
            continue
        }
        if ($null -eq $best -or $version -gt $best.Version)
        {
            $best = [PSCustomObject]@{
                Name       = $ModuleName
                Version    = $version
                ModuleBase = Split-Path $candidate.Path -Parent
                Path       = $candidate.Path
            }
        }
    }

    $best
}

function Get-DscFastCompileTiming
{
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if ($null -eq $script:FastHostTiming)
    {
        return $null
    }
    $copy = [ordered]@{}
    foreach ($entry in $script:FastHostTiming.GetEnumerator())
    {
        $copy[$entry.Key] = $entry.Value
    }
    $copy
}
Export-ModuleMember -Function Get-DscFastCompileTiming

function Invoke-DscFastCompile
{
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [System.String]
        $Path,

        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [System.String]
        $ScriptText,

        [System.String]
        $ConfigurationName,

        [System.Collections.Hashtable]
        $Parameters,

        [System.Object]
        $ConfigurationData,

        [System.String]
        $OutputPath,

        [System.String[]]
        $SchemaCachePath,

        [switch]
        $Force,

        [switch]
        $ValidateMof,

        [switch]
        $NoFallback
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path')
    {
        $Path = (Resolve-Path -Path $Path).ProviderPath
        $ScriptText = [System.IO.File]::ReadAllText($Path)
    }

    $timing = [ordered]@{}
    $script:FastHostTiming = $timing
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    Assert-DscConfigurationShim

    $fallbackReason = $null
    $stripResult = Get-StrippedConfigurationText -Text $ScriptText
    if (-not $stripResult.Supported)
    {
        $fallbackReason = $stripResult.Reason
    }
    $timing['parse'] = $stopwatch.ElapsedMilliseconds
    $stopwatch.Restart()

    $resolvedModules = @()
    if (-not $fallbackReason)
    {
        foreach ($spec in $stripResult.ModuleSpecs)
        {
            $specKey = "$($spec.ModuleName)|$($spec.ModuleVersion)"
            $module = $script:FastHostResolvedModules[$specKey]
            if ($null -eq $module)
            {
                $module = Resolve-FastHostModule -ModuleName $spec.ModuleName -ModuleVersion $spec.ModuleVersion
                if ($null -ne $module)
                {
                    $script:FastHostResolvedModules[$specKey] = $module
                }
            }

            if (-not $module)
            {
                $fallbackReason = "Module '$($spec.ModuleName)' $(if ($spec.ModuleVersion) { "version $($spec.ModuleVersion) " })was not found."
                break
            }
            $dscResourcesPath = Join-Path $module.ModuleBase 'DscResources'
            if (Test-Path $dscResourcesPath)
            {
                $compositeFiles = @([System.IO.Directory]::EnumerateFiles($dscResourcesPath, '*.schema.psm1', [System.IO.SearchOption]::AllDirectories))
                if ($compositeFiles.Count -gt 0)
                {
                    $fallbackReason = "Module '$($module.Name)' contains composite resources, which the fast host does not support yet."
                    break
                }
            }
            $resolvedModules += $module
        }
    }
    $timing['resolve'] = $stopwatch.ElapsedMilliseconds
    $stopwatch.Restart()

    if ($fallbackReason)
    {
        if ($NoFallback)
        {
            throw "Fast compilation is not possible: $fallbackReason"
        }
        Write-Warning -Message "Falling back to standard compilation: $fallbackReason"
        return Invoke-DscFastCompileBody -Text $ScriptText -ConfigurationName $ConfigurationName -Parameters $Parameters -ConfigurationData $ConfigurationData -OutputPath $OutputPath -ScriptPath $Path -ConfigurationNames $stripResult.ConfigurationNames
    }

    foreach ($module in $resolvedModules)
    {
        $registered = $script:FastHostRegisteredModules[$module.Name]
        if ($registered -and $registered -eq $module.Version.ToString() -and -not $Force)
        {
            continue
        }
        $cache = $null
        if (-not $Force)
        {
            $cache = Get-DscSchemaCache -Module $module -SchemaCachePath $SchemaCachePath
        }
        if (-not $cache)
        {
            $cache = New-DscSchemaCacheForModule -Module $module
        }
        if (-not $cache)
        {
            if ($NoFallback)
            {
                throw "No schema cache could be obtained for module '$($module.Name)' $($module.Version)."
            }
            Write-Warning -Message "Falling back to standard compilation: no usable schema cache for module '$($module.Name)' $($module.Version)."
            return Invoke-DscFastCompileBody -Text $ScriptText -ConfigurationName $ConfigurationName -Parameters $Parameters -ConfigurationData $ConfigurationData -OutputPath $OutputPath -ScriptPath $Path -ConfigurationNames $stripResult.ConfigurationNames
        }
        Register-DscSchemaCache -Cache $cache
        $script:FastHostRegisteredModules[$module.Name] = $module.Version.ToString()
    }
    $timing['cache'] = $stopwatch.ElapsedMilliseconds
    $stopwatch.Restart()

    $keywordNames = Get-FastHostKeywordName
    $compileText = ConvertTo-FastHostCompileText -Text $ScriptText -Ast $stripResult.Ast -ImportStatement $stripResult.ImportStatements -KeywordNames $keywordNames -Merge -Convert
    $timing['rewrite'] = $stopwatch.ElapsedMilliseconds
    $stopwatch.Restart()

    $script:FastHostActive = $true
    $script:FastHostValidateMof = [bool]$ValidateMof
    $Global:PSDscFastCompileActive = $true
    try
    {
        Invoke-DscFastCompileBody -Text $compileText -ConfigurationName $ConfigurationName -Parameters $Parameters -ConfigurationData $ConfigurationData -OutputPath $OutputPath -ScriptPath $Path -ConfigurationNames $stripResult.ConfigurationNames
    }
    finally
    {
        $script:FastHostActive = $false
        $script:FastHostValidateMof = $false
        $Global:PSDscFastCompileActive = $false
        [System.Management.Automation.Language.DynamicKeyword]::Reset()
        $timing['compile'] = $stopwatch.ElapsedMilliseconds
        $timing['total'] = $total.ElapsedMilliseconds
    }
}
Export-ModuleMember -Function Invoke-DscFastCompile

function Invoke-DscFastCompileBody
{
    param (
        [Parameter(Mandatory)]
        [System.String]
        $Text,

        [System.String]
        $ConfigurationName,

        [System.Collections.Hashtable]
        $Parameters,

        [System.Object]
        $ConfigurationData,

        [System.String]
        $OutputPath,

        [System.String]
        $ScriptPath,

        [System.String[]]
        $ConfigurationNames
    )

    $scriptBlock = [ScriptBlock]::Create($Text)
    $script:FastHostScriptPath = $ScriptPath

    # Parsing the configuration statement makes the engine load the inbox module by
    # file path, which takes the qualified Configuration name over.
    Assert-DscConfigurationShim

    $pushed = $false
    if ($ScriptPath)
    {
        Push-Location -Path (Split-Path $ScriptPath -Parent)
        $pushed = $true
    }
    try
    {
        $selfInvocationOutput = @(. $scriptBlock)
        $mofFiles = @($selfInvocationOutput | Where-Object { $_ -is [System.IO.FileInfo] })
        if ($mofFiles.Count -gt 0)
        {
            return $mofFiles
        }

        if (-not $ConfigurationName)
        {
            if ($ConfigurationNames.Count -eq 1)
            {
                $ConfigurationName = $ConfigurationNames[0]
            }
            else
            {
                throw "The script defines $($ConfigurationNames.Count) configurations ($($ConfigurationNames -join ', ')); specify -ConfigurationName."
            }
        }

        $invokeArguments = @{}
        if ($Parameters)
        {
            $invokeArguments = $Parameters.Clone()
        }
        if ($null -ne $ConfigurationData)
        {
            $invokeArguments['ConfigurationData'] = $ConfigurationData
        }
        if ($OutputPath)
        {
            $invokeArguments['OutputPath'] = $OutputPath
        }

        & $ConfigurationName @invokeArguments
    }
    finally
    {
        if ($pushed)
        {
            Pop-Location
        }
    }
}
