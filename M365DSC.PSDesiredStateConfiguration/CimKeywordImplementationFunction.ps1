
    param (
        [Parameter(Mandatory)]
            $KeywordData,
        [Parameter(Mandatory)]
            $Name,
        [Parameter(Mandatory)]
        [Hashtable]
            $Value,
        [Parameter(Mandatory)]
            $SourceMetadata
    )

$complexResourceQualifier = Get-ComplexResourceQualifier -IncludeCurrent

#
# Utility function used to validate that the DependsOn arguments are well-formed.
# The function also adds them to the define nodes resource collection.
# in the case of resources generated inside a script resource, this routine
# will also fix up the DependsOn references to '[Type]Instance::[OuterType]::OuterInstance
#
    function Test-DependsOn
    {

        # make sure the references are well-formed
        $updatedDependsOn = foreach ($DependsOnVar in $value['DependsOn']) {
        # match [ResourceType]ResourceName. ResourceName should starts with [a-z_0-9] followed by [a-z_0-9\p{Zs}\.\\-]*
            if ($DependsOnVar -notmatch '^\[[a-z]\w*\][a-z_0-9][a-z_0-9\p{Zs}\.\\-]*$')
            {
                Update-ConfigurationErrorCount
                Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetBadlyFormedRequiredResourceIdErrorRecord($DependsOnVar, $resourceId))
            }

            # Fix up DependsOn for nested names
            if ($MyTypeName -and $typeName -ne $MyTypeName -and $InstanceName)
            {
                "$DependsOnVar::$complexResourceQualifier"
            }
            else
            {
                $DependsOnVar
            }
        }

        $value['DependsOn']= $updatedDependsOn

        if($null -ne $DependsOn)
        {
            # Combine DependsOn with dependson from outer composite resource
            # which is set as local variable $DependsOn at the composite resource context
            $value['DependsOn']= @($value['DependsOn']) + $DependsOn
        }

        # Save the resource id in a per-node dictionary to do cross validation at the end
        Set-NodeResources $resourceId @( $value['DependsOn'])

        # Remove depends on because it need to be fixed up for composite resources
        # We do it in ValidateNodeResource and Update-Depends on in configuration/Node function
        $value.Remove('DependsOn')
    }

    # A copy of the value object with correctly-cased property names
    $canonicalizedValue = @{}

    $typeName = $keywordData.ResourceName # CIM type
    $keywordName = $keywordData.Keyword   # user-friendly alias that is used in scripts
    $keyValues = ''
    $debugPrefix = "   ${TypeName}:" # set up a debug prefix string that makes it easier to track what's happening.

    Write-Debug "${debugPrefix} RESOURCE PROCESSING STARTED [KeywordName='$keywordName'] Function='$($myinvocation.Invocationname)']"

    # Check whether it's an old style metaconfig
    $OldMetaConfig = $false
    if ((-not $IsMetaConfig) -and ($keywordName -ieq 'LocalConfigurationManager')) {
        $OldMetaConfig = $true
    }

    # Check to see if it's a resource keyword. If so add the meta-properties to the canonical property collection.
    $resourceId = $null
    # todo: need to include configuration managers and partial configuration
    if (($keywordData.Properties.Keys -contains 'DependsOn') -or (($KeywordData.ImplementingModule -ieq 'PSDesiredStateConfigurationEngine') -and ($KeywordData.NameMode -eq [System.Management.Automation.Language.DynamicKeywordNameMode]::NameRequired)))
    {

        $resourceId = "[$keywordName]$name"
        if ($MyTypeName -and $keywordName -ne $MyTypeName -and $InstanceName)
        {
            $resourceId += "::$complexResourceQualifier"
        }

        Write-Debug "${debugPrefix} ResourceID = $resourceId"

    # copy the meta-properties
        $canonicalizedValue['ResourceID'] = $resourceId
        $canonicalizedValue['SourceInfo'] = $SourceMetadata
        if(-not $IsMetaConfig)
        {
            $canonicalizedValue['ModuleName'] = $keywordData.ImplementingModule
            $canonicalizedValue['ModuleVersion'] = $keywordData.ImplementingModuleVersion -as [string]
        }

        # see if there is already a resource with this ID.
        if (Test-NodeResources $resourceId)
        {
            Update-ConfigurationErrorCount
            Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::DuplicateResourceIdInNodeStatementErrorRecord($resourceId, (Get-PSCurrentConfigurationNode)))
        }
        else
        {
            # If there are prerequisite resources, validate that the references are well-formed strings
            # This routine also adds the resource to the global node resources table.
            Test-DependsOn

        # Check if PsDscRunCredential is being specified as Arguments to Configuration
        if($null -ne $PsDscRunAsCredential)
        {
        # Check if resource is also trying to set the value for RunAsCred
        # In that case we will generate error during compilation, this is merge error
        if($null -ne $value['PsDscRunAsCredential'])
        {
            Update-ConfigurationErrorCount
            Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::PsDscRunAsCredentialMergeErrorForCompositeResources($resourceId))
        }
        # Set the Value of RunAsCred to that of outer configuration
        else
        {
            $value['PsDscRunAsCredential'] = $PsDscRunAsCredential
        }
    }

            # Save the resource id in a per-node dictionary to do cross validation at the end
            if($keywordData.ImplementingModule -ieq "PSDesiredStateConfigurationEngine")
            {
                #$keywordName is PartialConfiguration
                if($keywordName -eq 'PartialConfiguration')
                {
                    # RefreshMode is 'Pull' and .ConfigurationSource is empty
                    if($value['RefreshMode'] -eq 'Pull' -and -not $value['ConfigurationSource'])
                    {
                        Update-ConfigurationErrorCount
                        Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetPullModeNeedConfigurationSource($resourceId))
                    }

                    # Verify that RefreshMode is not Disabled for Partial configuration
                    if($value['RefreshMode'] -eq 'Disabled')
                    {
                        Update-ConfigurationErrorCount
                        Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::DisabledRefreshModeNotValidForPartialConfig($resourceId))
                    }

                    if($null -ne $value['ConfigurationSource'])
                    {
                        Set-NodeManager $resourceId $value['ConfigurationSource']
                    }

                    if($null -ne $value['ResourceModuleSource'])
                    {
                        Set-NodeResourceSource $resourceId $value['ResourceModuleSource']
                    }
                }

                if($null -ne $value['ExclusiveResources'])
                {
                    # make sure the references are well-formed
                    foreach ($ExclusiveResource in $value['ExclusiveResources']) {
                        if (($ExclusiveResource -notmatch '^[a-z][a-z_0-9]*\\[a-z][a-z_0-9]*$') -and ($ExclusiveResource -notmatch '^[a-z][a-z_0-9]*$') -and ($ExclusiveResource -notmatch '^[a-z][a-z_0-9]*\\\*$'))
                        {
                            Update-ConfigurationErrorCount
                            Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::GetBadlyFormedExclusiveResourceIdErrorRecord($ExclusiveResource, $resourceId))
                        }
                    }

                    # Save the resource id in a per-node dictionary to do cross validation at the end
                    # Validate resource exist
                    # Also update the resource reference from module\friendlyname to module\name
                    $value['ExclusiveResources'] = @(Set-NodeExclusiveResources $resourceId @( $value['ExclusiveResources'] ))
                }
            }
        }
    }
    else
    {
        Write-Debug "${debugPrefix} TYPE IS NOT AS DSC RESOURCE"
    }

    # Copy the user-supplied values into a new collection with canonicalized property names
    foreach ($key in $keywordData.Properties.Keys)
    {
        Write-Debug "${debugPrefix} Processing property '$key' ["

        if ($value.Contains($key))
        {
            if ($OldMetaConfig -and (-not ($V1MetaConfigPropertyList -contains $key)))
            {
                Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::InvalidLocalConfigurationManagerPropertyErrorRecord($key, ($V1MetaConfigPropertyList -join ', ')))
                Update-ConfigurationErrorCount
            }
            # see if there is a list of allowed values for this property (similar to an enum)
            $allowedValues = $keywordData.Properties[$key].Values
            # If there is and user-provided value is not in that list, write an error.
            if ($allowedValues)
            {
                if(($null -eq $value[$key]) -and ($allowedValues -notcontains $value[$key]))
                {
                    Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::InvalidValueForPropertyErrorRecord($key, "$($value[$key])", $keywordData.Keyword, ($allowedValues -join ', ')))
                    Update-ConfigurationErrorCount
                }
                else
                {
                    $notAllowedValue=$null
                    foreach($v in $value[$key])
                    {
                        if($allowedValues -notcontains $v)
                        {
                            $notAllowedValue +=$v.ToString() + ', '
                        }
                    }

                    if($notAllowedValue)
                    {
                        $notAllowedValue = $notAllowedValue.Substring(0, $notAllowedValue.Length -2)
                        Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::UnsupportedValueForPropertyErrorRecord($key, $notAllowedValue, $keywordData.Keyword, ($allowedValues -join ', ')))
                        Update-ConfigurationErrorCount
                    }
                }
            }

            # see if a value range is defined for this property
            $allowedRange = $keywordData.Properties[$key].Range
            if($allowedRange)
            {
                $castedValue = $value[$key] -as [int]
                if((($castedValue -is [int]) -and (($castedValue -lt  $keywordData.Properties[$key].Range.Item1) -or ($castedValue -gt $keywordData.Properties[$key].Range.Item2))) -or ($null -eq $castedValue))
                {
                    Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ValueNotInRangeErrorRecord($key, $keywordName, $value[$key],  $keywordData.Properties[$key].Range.Item1,  $keywordData.Properties[$key].Range.Item2))
                    Update-ConfigurationErrorCount
                }
            }

            Write-Debug "${debugPrefix}        Canonicalized property '$key' = '$($value[$key])'"

            if ($keywordData.Properties[$key].IsKey)
            {
                if($null -eq $value[$key])
                {
                    $keyValues += "::__NULL__"
                }
                else
                {
                    $keyValues += "::" + $value[$key]
                }
            }

            # see if ValueMap is also defined for this property (actual values)
            $allowedValueMap = $keywordData.Properties[$key].ValueMap
            #if it is and the ValueMap contains the user-provided value as a key, use the actual value
            if ($allowedValueMap -and $allowedValueMap.ContainsKey($value[$key]))
            {
                $canonicalizedValue[$key] = $allowedValueMap[$value[$key]]
            }
            else
            {
                $canonicalizedValue[$key] = $value[$key]
            }
        }
        elseif ($keywordData.Properties[$key].Mandatory)
        {
            # If the property was mandatory but the user didn't provide a value, write and error.
            Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::MissingValueForMandatoryPropertyErrorRecord($keywordData.Keyword, $keywordData.Properties[$key].TypeConstraint, $Key))
            Update-ConfigurationErrorCount
        }

        Write-Debug "${debugPrefix}    Processing completed '$key' ]"
    }

    if($keyValues)
    {
        $keyValues = $keyValues.Substring(2) # Remove the leading '::'
        Add-NodeKeys $keyValues $keywordName
        Test-ConflictingResources $keywordName $canonicalizedValue $keywordData
    }

    # update OMI_ConfigurationDocument
    if($IsMetaConfig)
    {
        if($keywordData.ResourceName -eq 'OMI_ConfigurationDocument')
        {
            if($(Get-PSMetaConfigurationProcessed))
            {
                $PSMetaConfigDocumentInstVersionInfo = Get-PSMetaConfigDocumentInstVersionInfo
                $canonicalizedValue['MinimumCompatibleVersion']=$PSMetaConfigDocumentInstVersionInfo['MinimumCompatibleVersion']
            }
            else
            {
                Set-PSMetaConfigDocInsProcessedBeforeMeta
                $canonicalizedValue['MinimumCompatibleVersion']='1.0.0'
            }
        }

        if(($keywordData.ResourceName -eq 'MSFT_WebDownloadManager') `
            -or ($keywordData.ResourceName -eq 'MSFT_FileDownloadManager') `
            -or ($keywordData.ResourceName -eq 'MSFT_WebResourceManager') `
            -or ($keywordData.ResourceName -eq 'MSFT_FileResourceManager') `
            -or ($keywordData.ResourceName -eq 'MSFT_WebReportManager') `
            -or ($keywordData.ResourceName -eq 'MSFT_SignatureValidation') `
            -or ($keywordData.ResourceName -eq 'MSFT_PartialConfiguration'))
        {
            Set-PSMetaConfigVersionInfoV2
        }
    }
    elseif($keywordData.ResourceName -eq 'OMI_ConfigurationDocument')
    {
        $canonicalizedValue['MinimumCompatibleVersion']='1.0.0'
        $canonicalizedValue['CompatibleVersionAdditionalProperties']=@('Omi_BaseResource:ConfigurationName')
    }

    if(($keywordData.ResourceName -eq 'MSFT_DSCMetaConfiguration') -or ($keywordData.ResourceName -eq 'MSFT_DSCMetaConfigurationV2'))
    {
        if($canonicalizedValue['DebugMode'] -and @($canonicalizedValue['DebugMode']).Length -gt 1)
        {
            # we only allow one value for debug mode now.
            Write-Error -ErrorRecord ([Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::DebugModeShouldHaveOneValue())
            Update-ConfigurationErrorCount
        }
    }

    # Generate the MOF text for this resource instance.
    # when generate mof text for OMI_ConfigurationDocument we handle below two cases:
    # 1. we will add versioning related property based on meta configuration instance already process
    # 2. we update the existing OMI_ConfigurationDocument instance if it already exists when process meta configuration instance
    $aliasId = ConvertTo-MOFInstance $keywordName $canonicalizedValue

    # If a OMI_ConfigurationDocument is executed outside of a node statement, it becomes the default
    # for all nodes that don't have an explicit OMI_ConfigurationDocument declaration
    if ($keywordData.ResourceName -eq 'OMI_ConfigurationDocument' -and -not (Get-PSCurrentConfigurationNode))
    {
        $data = Get-MoFInstanceText $aliasId
        Write-Debug "${debugPrefix} DEFINING DEFAULT CONFIGURATION DOCUMENT: $data"
        Set-PSDefaultConfigurationDocument $data
    }

    Write-Debug "${debugPrefix} MOF alias for this resource is '$aliasId'"

    # always return the aliasId so the generated file will be well-formed if not valid
    $aliasId

    Write-Debug "${debugPrefix} RESOURCE PROCESSING COMPLETED. TOTAL ERROR COUNT: $(Get-ConfigurationErrorCount)"
