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
if ($args.Count -lt 1 -or $args[$args.Count - 1] -isnot [scriptblock])
{
    throw "Resource '$__fhKeywordName': expected a { } property block as the last argument."
}
$__fhBody = $args[$args.Count - 1]
$__fhName = ''
if ($__fhKeyword.NameMode -eq [System.Management.Automation.Language.DynamicKeywordNameMode]::NameRequired)
{
    if ($args.Count -lt 2 -or $args[0] -isnot [string])
    {
        throw "Resource '$__fhKeywordName': expected '$__fhKeywordName <instance name> { ... }'."
    }
    $__fhName = $args[0]
}
elseif ($args.Count -ge 2 -and $args[0] -is [string])
{
    $__fhName = $args[0]
}
$__fhValueScriptBlock = Get-FastHostBodyScriptBlock -Body $__fhBody
$__fhValue = . $__fhValueScriptBlock
if ($__fhValue -isnot [hashtable])
{
    throw "Resource '$__fhKeywordName': the property block could not be evaluated as a set of 'Name = Value' assignments."
}
$__fhSource = "$($MyInvocation.ScriptName)::$($MyInvocation.ScriptLineNumber)::$($MyInvocation.OffsetInLine)::$__fhKeywordName"
& (Get-CimKeywordImplementationFunction) -KeywordData $__fhKeyword -Name $__fhName -Value $__fhValue -SourceMetadata $__fhSource
'@

function Get-FastHostKeyword
{
    param (
        [Parameter(Mandatory)]
        [string]
        $Name
    )

    if ($script:FastHostKeywords)
    {
        $script:FastHostKeywords[$Name]
    }
}

function Get-FastHostBodyScriptBlock
{
    [OutputType([scriptblock])]
    param (
        [Parameter(Mandatory)]
        [scriptblock]
        $Body
    )

    $extent = $Body.Ast.Extent
    $cacheKey = "$($extent.File):$($extent.StartOffset):$($extent.EndOffset)"
    $cached = $script:FastHostBodyCache[$cacheKey]
    if ($null -eq $cached)
    {
        $text = $extent.Text
        $inner = $text.Substring(1, $text.Length - 2)
        $cached = [scriptblock]::Create('@{' + $inner + '}')
        $script:FastHostBodyCache[$cacheKey] = $cached
    }
    $cached
}

function Register-DscCachedKeywords
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
    $adapter = [scriptblock]::Create($script:FastHostAdapterText)

    foreach ($schemaObject in $Cache.keywords)
    {
        $keyword = ConvertFrom-DscKeywordSchemaObject -SchemaObject $schemaObject
        $script:FastHostKeywords[$keyword.Keyword] = $keyword
        $script:FastHostAdapters[$keyword.Keyword] = $adapter
        if ($keyword.ImplementingModule)
        {
            $script:FastHostAdapters["$($keyword.ImplementingModule)\$($keyword.Keyword)"] = $adapter
        }
    }
}

# Joins 'KeywordName [InstanceName] <newline> { ... }' into one statement. With the
# keyword unknown to the parser, a next-line brace parses as a separate scriptblock
# statement and the engine rejects the resource as undefined.
function Merge-FastHostResourceStatements
{
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]
        $Text,

        [Parameter(Mandatory)]
        $KeywordNames
    )

    $masked = [regex]::Replace($Text, '(?i)\bConfiguration\b', 'C0nfiguration')
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($masked, [ref]$tokens, [ref]$parseErrors)

    $splices = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $blocks = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StatementBlockAst] -or $args[0] -is [System.Management.Automation.Language.NamedBlockAst] }, $true)
    foreach ($block in $blocks)
    {
        $statements = $block.Statements
        for ($i = 0; $i -lt $statements.Count - 1; $i++)
        {
            $first = $statements[$i]
            if ($first -isnot [System.Management.Automation.Language.PipelineAst] -or $first.PipelineElements.Count -ne 1)
            {
                continue
            }
            $command = $first.PipelineElements[0] -as [System.Management.Automation.Language.CommandAst]
            if ($null -eq $command -or $command.CommandElements.Count -gt 2)
            {
                continue
            }
            $commandName = $command.GetCommandName()
            if (-not $commandName -or -not $KeywordNames.Contains($commandName))
            {
                continue
            }
            $second = $statements[$i + 1]
            if ($second -isnot [System.Management.Automation.Language.PipelineAst] -or $second.PipelineElements.Count -ne 1)
            {
                continue
            }
            $expression = $second.PipelineElements[0] -as [System.Management.Automation.Language.CommandExpressionAst]
            if ($null -eq $expression -or $expression.Expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst])
            {
                continue
            }
            $gapStart = $command.Extent.EndOffset
            $gapLength = $second.Extent.StartOffset - $gapStart
            if ($gapLength -gt 0)
            {
                $splices.Add([pscustomobject]@{ Start = $gapStart; Length = $gapLength })
            }
        }
    }

    foreach ($splice in ($splices | Sort-Object -Property Start -Descending))
    {
        $Text = $Text.Remove($splice.Start, $splice.Length).Insert($splice.Start, ' ')
    }
    $Text
}

function Get-StrippedConfigurationText
{
    param (
        [Parameter(Mandatory)]
        [string]
        $Text
    )

    $masked = [regex]::Replace($Text, '(?i)\bConfiguration\b', 'C0nfiguration')
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($masked, [ref]$tokens, [ref]$parseErrors)

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

    $stripped = $Text
    foreach ($statement in ($importStatements | Sort-Object -Property { $_.Extent.StartOffset } -Descending))
    {
        $stripped = $stripped.Remove($statement.Extent.StartOffset, $statement.Extent.EndOffset - $statement.Extent.StartOffset)
    }

    [PSCustomObject]@{
        Supported          = $true
        Reason             = $null
        Text               = $stripped
        ModuleSpecs        = $moduleSpecs
        ConfigurationNames = $configurationNames
    }
}

function Invoke-DscFastCompile
{
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param (
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]
        $Path,

        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [string]
        $ScriptText,

        [string]
        $ConfigurationName,

        [hashtable]
        $Parameters,

        [object]
        $ConfigurationData,

        [string]
        $OutputPath,

        [string[]]
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

    Assert-DscConfigurationShim

    $fallbackReason = $null
    $stripResult = Get-StrippedConfigurationText -Text $ScriptText
    if (-not $stripResult.Supported)
    {
        $fallbackReason = $stripResult.Reason
    }

    $resolvedModules = @()
    if (-not $fallbackReason)
    {
        foreach ($spec in $stripResult.ModuleSpecs)
        {
            $candidates = Get-Module -ListAvailable -Name $spec.ModuleName | Sort-Object -Property Version -Descending
            if ($spec.ModuleVersion)
            {
                $candidates = $candidates | Where-Object { $_.Version -eq $spec.ModuleVersion }
            }
            $module = $candidates | Select-Object -First 1
            if (-not $module)
            {
                $fallbackReason = "Module '$($spec.ModuleName)' $(if ($spec.ModuleVersion) { "version $($spec.ModuleVersion) " })was not found."
                break
            }
            $dscResourcesPath = Join-Path $module.ModuleBase 'DscResources'
            if (Test-Path $dscResourcesPath)
            {
                $schemaFiles = @([System.IO.Directory]::EnumerateFiles($dscResourcesPath, '*.schema.mof', [System.IO.SearchOption]::AllDirectories)) +
                    @([System.IO.Directory]::EnumerateFiles($dscResourcesPath, '*.schema.psm1', [System.IO.SearchOption]::AllDirectories))
                if ($schemaFiles.Count -gt 0)
                {
                    $fallbackReason = "Module '$($module.Name)' contains script-based or composite resources, which the fast host does not support yet."
                    break
                }
            }
            $resolvedModules += $module
        }
    }

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
        if ($registered -and $registered -eq $module.Version.ToString())
        {
            continue
        }
        $cache = Get-DscSchemaCache -Module $module -SchemaCachePath $SchemaCachePath
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
        Register-DscCachedKeywords -Cache $cache
        $script:FastHostRegisteredModules[$module.Name] = $module.Version.ToString()
    }

    $compileText = $stripResult.Text
    if ($script:FastHostKeywords -and $script:FastHostKeywords.Count -gt 0)
    {
        $compileText = Merge-FastHostResourceStatements -Text $compileText -KeywordNames $script:FastHostKeywords.Keys
    }

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
    }
}
Export-ModuleMember -Function Invoke-DscFastCompile

function Invoke-DscFastCompileBody
{
    param (
        [Parameter(Mandatory)]
        [string]
        $Text,

        [string]
        $ConfigurationName,

        [hashtable]
        $Parameters,

        [object]
        $ConfigurationData,

        [string]
        $OutputPath,

        [string]
        $ScriptPath,

        [string[]]
        $ConfigurationNames
    )

    $scriptBlock = [scriptblock]::Create($Text)

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
