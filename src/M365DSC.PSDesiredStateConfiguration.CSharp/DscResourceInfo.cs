using System;
using System.Collections.Generic;
using System.Management.Automation;

namespace Microsoft.PowerShell.DesiredStateConfiguration;

/// <summary>How a DSC resource is implemented.</summary>
public enum ImplementedAsType
{
    /// <summary>The implementation is not known.</summary>
    None = 0,

    /// <summary>The resource is implemented in a PowerShell module.</summary>
    PowerShell = 1,

    /// <summary>The resource is implemented by a CIM provider.</summary>
    Binary = 2,

    /// <summary>The resource is a composite implemented with the configuration keyword.</summary>
    Composite = 3,
}

/// <summary>Describes a DSC resource.</summary>
public sealed class DscResourceInfo
{
    /// <summary>Creates a resource description without properties.</summary>
    public DscResourceInfo()
    {
        Properties = [];
    }

    /// <summary>Gets or sets the resource type name.</summary>
    public string? ResourceType { get; set; }

    /// <summary>Gets or sets the name used to access the resource.</summary>
    public string? Name { get; set; }

    /// <summary>Gets or sets the friendly name defined for the resource.</summary>
    public string? FriendlyName { get; set; }

    /// <summary>Gets or sets the module that implements the resource, which can be the parent of the nested module that implements it.</summary>
    public PSModuleInfo? Module { get; set; }

    /// <summary>Gets the name of the module that implements the resource.</summary>
    public string? ModuleName => Module?.Name;

    /// <summary>Gets the version of the module that implements the resource.</summary>
    public Version? Version => Module?.Version;

    /// <summary>Gets or sets the file that implements the resource: the module beside the schema MOF, or the module of a composite resource.</summary>
    public string? Path { get; set; }

    /// <summary>Gets or sets the folder that holds the implementing module or the schema MOF, the only path a native provider has.</summary>
    public string? ParentPath { get; set; }

    /// <summary>Gets or sets how the resource is implemented.</summary>
    public ImplementedAsType ImplementedAs { get; set; }

    /// <summary>Gets or sets the company that owns the resource.</summary>
    public string? CompanyName { get; set; }

    /// <summary>Gets the properties of the resource.</summary>
    public List<DscResourcePropertyInfo> Properties { get; private set; }

    /// <summary>Replaces the properties of the resource.</summary>
    /// <param name="properties">The new properties.</param>
    public void UpdateProperties(List<DscResourcePropertyInfo> properties)
    {
        Properties = properties;
    }
}

/// <summary>Describes a property of a DSC resource.</summary>
public sealed class DscResourcePropertyInfo
{
    /// <summary>Creates a property description without values.</summary>
    public DscResourcePropertyInfo()
    {
        Values = [];
    }

    /// <summary>Gets or sets the name of the property.</summary>
    public string? Name { get; set; }

    /// <summary>Gets or sets the type of the property.</summary>
    public string? PropertyType { get; set; }

    /// <summary>Gets or sets a value indicating whether the property is mandatory.</summary>
    public bool IsMandatory { get; set; }

    /// <summary>Gets the values the property allows.</summary>
    public List<string> Values { get; private set; }
}
