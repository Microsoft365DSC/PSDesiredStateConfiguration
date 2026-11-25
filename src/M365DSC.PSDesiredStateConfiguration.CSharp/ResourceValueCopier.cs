using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text;

namespace M365DSC.PSDesiredStateConfiguration;

/// <summary>Copies the values of a resource instance under their schema names for the values that raise no error.</summary>
public static class ResourceValueCopier
{
    /// <summary>Returns the key values joined as the keyword implementation joins them, or null when a property needs the PowerShell path.</summary>
    public static string? CopyValues(IDictionary? value, DynamicKeyword? keyword, IDictionary? canonical)
    {
        if (value is null || keyword is null || canonical is null)
        {
            return null;
        }

        var copied = new Dictionary<string, object?>(StringComparer.Ordinal);
        var keyValues = new StringBuilder();

        foreach (KeyValuePair<string, DynamicKeywordProperty> entry in keyword.Properties)
        {
            string key = entry.Key;
            DynamicKeywordProperty property = entry.Value;

            if (!value.Contains(key))
            {
                if (property.Mandatory)
                {
                    return null;
                }

                continue;
            }

            object? item = value[key];

            if (property.Range is not null)
            {
                return null;
            }

            if (IsTrue(property.Values) && !AreAllowed(item, property.Values))
            {
                return null;
            }

            if (property.IsKey)
            {
                switch (item)
                {
                    case null:
                        keyValues.Append("::__NULL__");
                        break;
                    case string text:
                        keyValues.Append("::").Append(text);
                        break;
                    default:
                        return null;
                }
            }

            if (property.ValueMap is { Count: > 0 } valueMap)
            {
                if (item is not string text)
                {
                    return null;
                }

                copied[key] = valueMap.TryGetValue(text, out string? mapped) ? mapped : item;
            }
            else
            {
                copied[key] = item;
            }
        }

        foreach (KeyValuePair<string, object?> entry in copied)
        {
            canonical[entry.Key] = entry.Value;
        }

        return keyValues.ToString();
    }

    private static bool IsTrue(List<string>? values)
    {
        return values is not null && (values.Count > 1 || (values.Count == 1 && !string.IsNullOrEmpty(values[0])));
    }

    private static bool AreAllowed(object? item, List<string> allowed)
    {
        switch (item)
        {
            case string text:
                return IsAllowed(text, allowed);
            case Array array:
                foreach (object? element in array)
                {
                    if (element is not string elementText || !IsAllowed(elementText, allowed))
                    {
                        return false;
                    }
                }

                return true;
            default:
                return false;
        }
    }

    private static bool IsAllowed(string text, List<string> allowed)
    {
        foreach (string candidate in allowed)
        {
            if (LanguagePrimitives.Equals(candidate, text, true, CultureInfo.InvariantCulture))
            {
                return true;
            }
        }

        return false;
    }
}
