# Normalizes and compares two compiled DSC MOF files for semantic equivalence.
# Exit code 0 = equivalent, 1 = different (or use -PassThru for a boolean).
[CmdletBinding(DefaultParameterSetName = 'Compare')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]
    $ReferencePath,

    [Parameter(Mandatory, ParameterSetName = 'Compare')]
    [string]
    $CandidatePath,

    [Parameter(ParameterSetName = 'Compare')]
    [switch]
    $PassThru,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]
    $SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:VolatileDocumentProperties = @('GenerationDate', 'GenerationHost', 'Author', 'ContentType')

function Remove-MofBanner
{
    param ([string]$Text)

    $trimmed = $Text.TrimStart()
    if ($trimmed.StartsWith('/*'))
    {
        $end = $trimmed.IndexOf('*/')
        if ($end -ge 0)
        {
            return $trimmed.Substring($end + 2)
        }
    }
    $Text
}

function Remove-WhitespaceOutsideStrings
{
    param ([string]$Text)

    $sb = New-Object -TypeName System.Text.StringBuilder
    $inString = $false
    for ($i = 0; $i -lt $Text.Length; $i++)
    {
        $c = $Text[$i]
        if ($inString)
        {
            $null = $sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $Text.Length)
            {
                $i++
                $null = $sb.Append($Text[$i])
            }
            elseif ($c -eq '"')
            {
                $inString = $false
            }
        }
        else
        {
            if ([char]::IsWhiteSpace($c))
            {
                continue
            }
            $null = $sb.Append($c)
            if ($c -eq '"')
            {
                $inString = $true
            }
        }
    }
    $sb.ToString()
}

function Split-MofProperties
{
    param ([string]$Body)

    $props = @()
    $depth = 0
    $inString = $false
    $start = 0
    for ($i = 0; $i -lt $Body.Length; $i++)
    {
        $c = $Body[$i]
        if ($inString)
        {
            if ($c -eq '\') { $i++ }
            elseif ($c -eq '"') { $inString = $false }
        }
        else
        {
            if ($c -eq '"') { $inString = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth-- }
            elseif ($c -eq ';' -and $depth -le 0)
            {
                $raw = $Body.Substring($start, $i - $start)
                if ($raw.Trim().Length -gt 0) { $props += , $raw }
                $start = $i + 1
            }
        }
    }
    $tail = $Body.Substring($start)
    if ($tail.Trim().Length -gt 0) { $props += , $tail }
    , $props
}

function ConvertTo-CanonicalProperty
{
    param ([string]$Raw)

    $eqIdx = -1
    $inString = $false
    for ($i = 0; $i -lt $Raw.Length; $i++)
    {
        $c = $Raw[$i]
        if ($inString)
        {
            if ($c -eq '\') { $i++ }
            elseif ($c -eq '"') { $inString = $false }
        }
        else
        {
            if ($c -eq '"') { $inString = $true }
            elseif ($c -eq '=') { $eqIdx = $i; break }
        }
    }
    if ($eqIdx -lt 0)
    {
        $name = $Raw.Trim()
        return [PSCustomObject]@{ Name = $name; Value = ''; Text = $name }
    }
    $name = $Raw.Substring(0, $eqIdx).Trim()
    $value = Remove-WhitespaceOutsideStrings -Text $Raw.Substring($eqIdx + 1)
    [PSCustomObject]@{ Name = $name; Value = $value; Text = "$name = $value" }
}

function Get-MofBlocks
{
    param ([string]$Text)

    $blocks = New-Object -TypeName System.Collections.ArrayList
    $pos = 0
    $n = $Text.Length
    while ($pos -lt $n)
    {
        $idx = $Text.IndexOf('instance of', $pos, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { break }
        $braceIdx = $Text.IndexOf('{', $idx)
        if ($braceIdx -lt 0) { break }
        $header = $Text.Substring($idx, $braceIdx - $idx)
        $m = [regex]::Match($header, '^instance\s+of\s+([^\s{]+)(?:\s+as\s+(\$[A-Za-z0-9_]+))?\s*$', 'IgnoreCase')
        if (-not $m.Success)
        {
            $pos = $idx + 11
            continue
        }
        $class = $m.Groups[1].Value
        $alias = $null
        if ($m.Groups[2].Success) { $alias = $m.Groups[2].Value }

        $depth = 1
        $inString = $false
        $j = $braceIdx + 1
        while ($j -lt $n -and $depth -gt 0)
        {
            $c = $Text[$j]
            if ($inString)
            {
                if ($c -eq '\') { $j++ }
                elseif ($c -eq '"') { $inString = $false }
            }
            else
            {
                if ($c -eq '"') { $inString = $true }
                elseif ($c -eq '{') { $depth++ }
                elseif ($c -eq '}') { $depth-- }
            }
            $j++
        }
        $body = $Text.Substring($braceIdx + 1, ($j - 1) - ($braceIdx + 1))

        $isDocument = ($class -ieq 'OMI_ConfigurationDocument')
        $props = @()
        $resourceId = $null
        foreach ($raw in (Split-MofProperties -Body $body))
        {
            $prop = ConvertTo-CanonicalProperty -Raw $raw
            if ($isDocument -and ($script:VolatileDocumentProperties -contains $prop.Name))
            {
                continue
            }
            if ($prop.Name -ieq 'ResourceID')
            {
                $resourceId = $prop.Value.Trim('"')
            }
            $propText = $prop.Text
            if ($prop.Name -ieq 'SourceInfo')
            {
                # Source positions drift across compile paths (import stripping, statement
                # merging); keep only the trailing keyword name.
                $si = [regex]::Match($prop.Value, '^"(.*)"$')
                if ($si.Success)
                {
                    $segments = $si.Groups[1].Value -split '::'
                    $propText = $prop.Name + ' = "::' + $segments[$segments.Count - 1] + '"'
                }
            }
            $props += , $propText
        }

        $null = $blocks.Add([PSCustomObject]@{
                Class      = $class
                Alias      = $alias
                Props      = $props
                ResourceID = $resourceId
                IdToken    = $null
            })
        $pos = $j
    }
    , $blocks
}

function Get-ContentHashToken
{
    param ([string]$Class, [string[]]$Props)

    $sorted = @($Props | ForEach-Object { $_ })
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    $payload = $Class + "`n" + ($sorted -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))
    }
    finally
    {
        $sha.Dispose()
    }
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    '@Hash:' + $hex.Substring(0, 16)
}

function Resolve-MofAliases
{
    param ($Blocks)

    $aliasToToken = @{}
    $allAliases = @()
    foreach ($block in $Blocks)
    {
        if ($block.Alias)
        {
            $allAliases += $block.Alias
            if ($block.ResourceID)
            {
                $block.IdToken = '@ResourceID:' + $block.ResourceID
                $aliasToToken[$block.Alias] = $block.IdToken
            }
        }
        elseif ($block.ResourceID)
        {
            $block.IdToken = '@ResourceID:' + $block.ResourceID
        }
    }

    $substitute = {
        param ([string]$Line, [hashtable]$Map)
        $result = $Line
        foreach ($alias in ($Map.Keys | Sort-Object -Property Length -Descending))
        {
            $result = [regex]::Replace($result, [regex]::Escape($alias) + '(?![A-Za-z0-9_])', $Map[$alias].Replace('$', '$$'))
        }
        $result
    }

    $progress = $true
    while ($progress)
    {
        $progress = $false
        foreach ($block in $Blocks)
        {
            if (-not $block.Alias -or $null -ne $block.IdToken) { continue }
            $resolvedProps = @()
            $blocked = $false
            foreach ($prop in $block.Props)
            {
                $line = & $substitute $prop $aliasToToken
                foreach ($alias in $allAliases)
                {
                    if (-not $aliasToToken.ContainsKey($alias) -and $line -match ([regex]::Escape($alias) + '(?![A-Za-z0-9_])'))
                    {
                        $blocked = $true
                        break
                    }
                }
                if ($blocked) { break }
                $resolvedProps += , $line
            }
            if ($blocked) { continue }
            $block.IdToken = Get-ContentHashToken -Class $block.Class -Props $resolvedProps
            $aliasToToken[$block.Alias] = $block.IdToken
            $progress = $true
        }
    }

    foreach ($block in $Blocks)
    {
        if ($block.Alias -and $null -eq $block.IdToken)
        {
            $block.IdToken = '@Cycle:' + $block.Class
            $aliasToToken[$block.Alias] = $block.IdToken
        }
    }

    foreach ($block in $Blocks)
    {
        $newProps = @()
        foreach ($prop in $block.Props)
        {
            $newProps += , (& $substitute $prop $aliasToToken)
        }
        $block.Props = $newProps
    }
}

function ConvertTo-NormalizedMofLines
{
    param ([string]$Text)

    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $Text = Remove-MofBanner -Text $Text
    $blocks = Get-MofBlocks -Text $Text
    Resolve-MofAliases -Blocks $blocks

    $lines = @()
    $sortedBlocks = @($blocks | Sort-Object -Property @{ Expression = { '{0}|{1}' -f $_.Class, [string]$_.IdToken } })
    foreach ($block in $sortedBlocks)
    {
        $props = @($block.Props | ForEach-Object { $_ })
        [System.Array]::Sort($props, [System.StringComparer]::Ordinal)
        $lines += , ('instance of ' + $block.Class)
        $lines += , '{'
        foreach ($prop in $props)
        {
            $lines += , ($prop + ';')
        }
        $lines += , '};'
    }
    , $lines
}

function Compare-NormalizedLines
{
    param ([string[]]$ReferenceLines, [string[]]$CandidateLines)

    $max = [System.Math]::Max($ReferenceLines.Count, $CandidateLines.Count)
    $shown = 0
    $equal = $true
    for ($i = 0; $i -lt $max; $i++)
    {
        $refLine = '<missing>'
        $candLine = '<missing>'
        if ($i -lt $ReferenceLines.Count) { $refLine = $ReferenceLines[$i] }
        if ($i -lt $CandidateLines.Count) { $candLine = $CandidateLines[$i] }
        if ([string]::CompareOrdinal($refLine, $candLine) -ne 0)
        {
            $equal = $false
            if ($shown -eq 0)
            {
                Write-Host ('--- MOF difference starting at normalized line {0} ---' -f ($i + 1))
            }
            if ($shown -lt 40)
            {
                Write-Host ('<= ' + $refLine)
                Write-Host ('=> ' + $candLine)
                $shown++
            }
            else
            {
                Write-Host '... (further differences truncated)'
                break
            }
        }
    }
    $equal
}

function Compare-MofFiles
{
    param ([string]$Reference, [string]$Candidate)

    $refText = [System.IO.File]::ReadAllText((Resolve-Path -Path $Reference).ProviderPath)
    $candText = [System.IO.File]::ReadAllText((Resolve-Path -Path $Candidate).ProviderPath)
    $refLines = ConvertTo-NormalizedMofLines -Text $refText
    $candLines = ConvertTo-NormalizedMofLines -Text $candText
    Compare-NormalizedLines -ReferenceLines $refLines -CandidateLines $candLines
}

function Invoke-SelfTest
{
    $reference = @'
/*
@TargetNode='localhost'
@GeneratedBy=userA
@GenerationDate=08/11/2026 10:00:00
@GenerationHost=HOSTA
*/

instance of MSFT_Credential as $MSFT_Credential1ref
{
Password = "secret";
 UserName = "user1";
};

instance of xTestClassResource as $xTestClassResource1ref
{
ResourceID = "[xTestClassResource]Instance1";
 Name = "Instance1";
 Value = "Value1";
 sArray = {
    "s1",
    "s2"
};
 Credential = $MSFT_Credential1ref;
 SourceInfo = "::7::9::xTestClassResource";
 ModuleName = "xTestClassResource";
 ModuleVersion = "1.0";
 ConfigurationName = "DscBenchConfig";
};
instance of ResourceForTests1 as $ResourceForTests11ref
{
ResourceID = "[ResourceForTests1]Instance2";
 Prop1 = "Prop1-Instance2";
 ModuleName = "xTestClassResource";
 ModuleVersion = "1.0";
 ConfigurationName = "DscBenchConfig";
};
instance of OMI_ConfigurationDocument
{
 Version="2.0.0";
 MinimumCompatibleVersion = "1.0.0";
 CompatibleVersionAdditionalProperties= {"Omi_BaseResource:ConfigurationName"};
 Author="userA";
 GenerationDate="08/11/2026 10:00:00";
 GenerationHost="HOSTA";
 Name="DscBenchConfig";
};
'@

    $candidate = @'
instance of ResourceForTests1 as $ResourceForTests199ref
{
 ConfigurationName = "DscBenchConfig";
 ModuleVersion = "1.0";
 ModuleName = "xTestClassResource";
 Prop1 = "Prop1-Instance2";
ResourceID = "[ResourceForTests1]Instance2";
};
instance of xTestClassResource as $xTestClassResource42ref
{
 ConfigurationName = "DscBenchConfig";
 ModuleName = "xTestClassResource";
 Credential = $MSFT_Credential77ref;
 sArray = {"s1", "s2"};
 Value = "Value1";
 Name = "Instance1";
 SourceInfo = "C:\somewhere\else.ps1::6::9::xTestClassResource";
ResourceID = "[xTestClassResource]Instance1";
 ModuleVersion = "1.0";
};
instance of MSFT_Credential as $MSFT_Credential77ref
{
 UserName = "user1";
Password = "secret";
};
instance of OMI_ConfigurationDocument
{
 Version="2.0.0";
 GenerationHost="OTHERHOST";
 GenerationDate="01/01/2030 00:00:00";
 Author="userB";
 MinimumCompatibleVersion = "1.0.0";
 CompatibleVersionAdditionalProperties= {"Omi_BaseResource:ConfigurationName"};
 Name="DscBenchConfig";
};
'@

    $mutated = $candidate.Replace('Value = "Value1"', 'Value = "ValueX"')

    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dscmofcompare-selftest-' + [System.Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempDir -Force
    try
    {
        $refFile = Join-Path -Path $tempDir -ChildPath 'reference.mof'
        $candFile = Join-Path -Path $tempDir -ChildPath 'candidate.mof'
        $mutFile = Join-Path -Path $tempDir -ChildPath 'mutated.mof'
        [System.IO.File]::WriteAllText($refFile, $reference.Replace("`n", "`r`n"))
        [System.IO.File]::WriteAllText($candFile, $candidate)
        [System.IO.File]::WriteAllText($mutFile, $mutated)

        $positive = Compare-MofFiles -Reference $refFile -Candidate $candFile
        if ($positive)
        {
            Write-Host 'SelfTest positive case (equivalent files): PASS'
        }
        else
        {
            Write-Host 'SelfTest positive case (equivalent files): FAIL'
        }

        $negative = -not (Compare-MofFiles -Reference $refFile -Candidate $mutFile)
        if ($negative)
        {
            Write-Host 'SelfTest negative case (difference detected): PASS'
        }
        else
        {
            Write-Host 'SelfTest negative case (difference detected): FAIL'
        }

        if ($positive -and $negative)
        {
            Write-Host 'SelfTest: PASS'
            return $true
        }
        Write-Host 'SelfTest: FAIL'
        return $false
    }
    finally
    {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($PSCmdlet.ParameterSetName -eq 'SelfTest')
{
    if (Invoke-SelfTest) { exit 0 } else { exit 1 }
}

$result = Compare-MofFiles -Reference $ReferencePath -Candidate $CandidatePath
if ($PassThru)
{
    $result
}
else
{
    if ($result) { exit 0 } else { exit 1 }
}
