using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text.RegularExpressions;

namespace M365DSC.PSDesiredStateConfiguration;

/// <summary>Writes the property lines of a MOF instance for the value types stringify handles without PowerShell.</summary>
public static class MofPropertyWriter
{
    private const RegexOptions TypeNameOptions = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private static readonly Regex ArrayTypePattern = new("Array", TypeNameOptions);
    private static readonly Regex SignedPattern = new("^sint[0-9]{1,2}", TypeNameOptions);
    private static readonly Regex CharPattern = new("^char16", TypeNameOptions);
    private static readonly Regex UnsignedPattern = new("^uint[0-9]{0,2}", TypeNameOptions);
    private static readonly Regex RealPattern = new("^real32|^real64", TypeNameOptions);
    private static readonly Regex BooleanPattern = new("^boolean", TypeNameOptions);
    private static readonly Regex DateTimePattern = new("datetime", TypeNameOptions);
    private static readonly Regex LineBreakPattern = new("\r?\n", RegexOptions.CultureInvariant);

    private enum TargetKind
    {
        Text,
        Boolean,
        Signed,
        Unsigned,
        Other,
    }

    /// <summary>
    /// Writes the property lines of one MOF instance in ordinal property name order, in the format of the
    /// PowerShell <c>stringify</c> function: <c>Name = value;</c> lines joined by a space, strings quoted
    /// and escaped, arrays as braced lists, and embedded instance aliases written unquoted.
    /// </summary>
    /// <param name="properties">The property values of the instance, keyed by property name.</param>
    /// <param name="propertyTypes">The keyword properties of the resource, used for the MOF type of each value.</param>
    /// <param name="instanceAliases">The aliases of the embedded instances already written for the current node.</param>
    /// <returns>
    /// The property lines. <see langword="null"/> when <paramref name="properties"/> is empty, an argument is
    /// null, a key is not a string, an embedded instance value is null, a property has a char, real or
    /// datetime type, a value is a credential, hashtable, script block, wrapped object or non-array
    /// collection, or a value needs a PowerShell conversion to its MOF type, such as a string for a boolean,
    /// a decimal, or a negative number for an unsigned type. The PowerShell path then writes the instance.
    /// </returns>
    public static string? WriteProperties(IDictionary? properties, IDictionary<string, DynamicKeywordProperty>? propertyTypes, IDictionary? instanceAliases)
    {
        if (properties is null || properties.Count == 0 || instanceAliases is null || propertyTypes is null)
        {
            return null;
        }

        object[] keys = new object[properties.Count];
        properties.Keys.CopyTo(keys, 0);
        string[] names = new string[keys.Length];
        for (int index = 0; index < keys.Length; index++)
        {
            if (keys[index] is not string name)
            {
                return null;
            }

            names[index] = name;
        }

        Array.Sort(names, keys, StringComparer.Ordinal);

        string[] lines = new string[keys.Length];
        for (int index = 0; index < keys.Length; index++)
        {
            string name = names[index];
            object? value = properties[keys[index]];

            string? typeName = propertyTypes.TryGetValue(name, out DynamicKeywordProperty? property) ? property?.TypeConstraint : null;

            if (value is null && string.Equals(typeName, "Instance", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            bool asArray = string.Equals(name, "DependsOn", StringComparison.OrdinalIgnoreCase)
                || (typeName is not null && (ArrayTypePattern.IsMatch(typeName) || typeName.EndsWith("[]", StringComparison.Ordinal)));

            TargetKind kind = ResolveKind(typeName);
            if (kind == TargetKind.Other)
            {
                return null;
            }

            string? text = FormatValue(value, asArray, kind, instanceAliases);
            if (text is null)
            {
                return null;
            }

            lines[index] = name + " = " + text + ";\n";
        }

        return string.Join(" ", lines);
    }

    private static TargetKind ResolveKind(string? typeName)
    {
        string subject = typeName ?? string.Empty;

        if (SignedPattern.IsMatch(subject))
        {
            return TargetKind.Signed;
        }

        if (CharPattern.IsMatch(subject) || RealPattern.IsMatch(subject))
        {
            return TargetKind.Other;
        }

        if (UnsignedPattern.IsMatch(subject))
        {
            return TargetKind.Unsigned;
        }

        bool isBoolean = BooleanPattern.IsMatch(subject);
        if (DateTimePattern.IsMatch(subject))
        {
            return TargetKind.Other;
        }

        return isBoolean ? TargetKind.Boolean : TargetKind.Text;
    }

    private static string? FormatValue(object? value, bool asArray, TargetKind kind, IDictionary instanceAliases)
    {
        if (value is PSObject or PSCredential or Hashtable or ScriptBlock)
        {
            return null;
        }

        if (value is Array || asArray)
        {
            return FormatArray(value, kind, instanceAliases);
        }

        return kind switch
        {
            TargetKind.Boolean => FormatBoolean(value),
            TargetKind.Signed => FormatSigned(value),
            TargetKind.Unsigned => FormatUnsigned(value),
            _ => FormatText(value, instanceAliases),
        };
    }

    private static string? FormatArray(object? value, TargetKind kind, IDictionary instanceAliases)
    {
        var parts = new List<string> { "{" };
        switch (value)
        {
            case Array array:
                int remaining = array.Length;
                foreach (object? element in array)
                {
                    string? formatted = FormatValue(element, false, kind, instanceAliases);
                    if (formatted is null)
                    {
                        return null;
                    }

                    parts.Add("    " + formatted + (--remaining > 0 ? "," : string.Empty));
                }

                break;
            case null:
                break;
            case IEnumerable and not string:
                return null;
            default:
                string? single = FormatValue(value, false, kind, instanceAliases);
                if (single is null)
                {
                    return null;
                }

                parts.Add("    " + single);
                break;
        }

        parts.Add("}");
        return string.Join("\n", parts);
    }

    private static string? FormatBoolean(object? value)
    {
        return value switch
        {
            null => "False",
            bool truth => truth ? "True" : "False",
            _ => TryReadInteger(value, out long number) ? (number != 0 ? "True" : "False") : null,
        };
    }

    private static string? FormatSigned(object? value)
    {
        return value switch
        {
            null => "0",
            bool truth => truth ? "1" : "0",
            _ => TryReadInteger(value, out long number) ? number.ToString(CultureInfo.InvariantCulture) : null,
        };
    }

    private static string? FormatUnsigned(object? value)
    {
        return value switch
        {
            null => "0",
            bool truth => truth ? "1" : "0",
            ulong number => number.ToString(CultureInfo.InvariantCulture),
            _ => TryReadInteger(value, out long number) && number >= 0 ? number.ToString(CultureInfo.InvariantCulture) : null,
        };
    }

    private static string? FormatText(object? value, IDictionary instanceAliases)
    {
        switch (value)
        {
            case string text:
                return instanceAliases.Contains(text) && instanceAliases[text] is string { Length: > 0 } ? text : Quote(text);
            case null:
                return "NULL";
            case bool truth:
                return Quote(truth ? "True" : "False");
            case ulong number:
                return Quote(number.ToString(CultureInfo.InvariantCulture));
            default:
                return TryReadInteger(value, out long integer) ? Quote(integer.ToString(CultureInfo.InvariantCulture)) : null;
        }
    }

    private static string Quote(string text)
    {
        string escaped = text.Replace("\\", "\\\\");
        escaped = LineBreakPattern.Replace(escaped, "\\n");
        escaped = escaped.Replace("\"", "\\\"");
        return "\"" + escaped + "\"";
    }

    private static bool TryReadInteger(object? value, out long integer)
    {
        switch (value)
        {
            case int number:
                integer = number;
                return true;
            case long number:
                integer = number;
                return true;
            case short number:
                integer = number;
                return true;
            case byte number:
                integer = number;
                return true;
            case sbyte number:
                integer = number;
                return true;
            case ushort number:
                integer = number;
                return true;
            case uint number:
                integer = number;
                return true;
            default:
                integer = 0;
                return false;
        }
    }
}
