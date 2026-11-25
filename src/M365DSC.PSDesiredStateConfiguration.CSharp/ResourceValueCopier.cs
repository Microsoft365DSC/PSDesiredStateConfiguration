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
    /// <summary>
    /// Copies the values a resource instance sets into <paramref name="canonical"/> under the property
    /// names of the keyword schema, applying the value map of each property, and builds the key value
    /// string the keyword implementation uses to detect duplicate resources.
    /// Nothing is written to <paramref name="canonical"/> when the method returns <see langword="null"/>.
    /// </summary>
    /// <param name="value">The values the configuration sets on the resource instance, keyed by property name.</param>
    /// <param name="keyword">The keyword whose schema defines the properties, their key flags, allowed values and value maps.</param>
    /// <param name="canonical">The dictionary that receives the copied values under their schema property names.</param>
    /// <returns>
    /// The values of the key properties, each prefixed with <c>::</c> and <c>::__NULL__</c> for a null key,
    /// in the order of the keyword properties. <see langword="null"/> when any argument is null, the
    /// instance sets a property the schema lacks, a mandatory property is missing, a property has a range, a value is outside the allowed values, a key
    /// value is not a string, or a value of a mapped property is not a string. The PowerShell path then
    /// handles the instance and reports the error.
    /// </returns>
    public static string? CopyValues(IDictionary? value, DynamicKeyword? keyword, IDictionary? canonical)
    {
        if (value is null || keyword is null || canonical is null)
        {
            return null;
        }

        foreach (object? name in value.Keys)
        {
            if (name is not string text || !keyword.Properties.ContainsKey(text))
            {
                return null;
            }
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
