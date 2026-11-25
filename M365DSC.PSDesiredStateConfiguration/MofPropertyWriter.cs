using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text.RegularExpressions;

namespace M365DSC.PSDesiredStateConfiguration
{
    /// <summary>Copies the values of a resource instance under their schema names for the values that raise no error.</summary>
    public static class ResourceValueCopier
    {
        /// <summary>Returns the key values joined as the keyword implementation joins them, or null when a property needs the PowerShell path.</summary>
        public static string CopyValues(IDictionary value, DynamicKeyword keyword, IDictionary canonical)
        {
            if (value == null || keyword == null || canonical == null)
            {
                return null;
            }

            Dictionary<string, object> copied = new Dictionary<string, object>(StringComparer.Ordinal);
            string keyValues = string.Empty;

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

                object item = value[key];

                if (property.Range != null)
                {
                    return null;
                }

                if (IsTrue(property.Values) && !AreAllowed(item, property.Values))
                {
                    return null;
                }

                if (property.IsKey)
                {
                    if (item == null)
                    {
                        keyValues += "::__NULL__";
                    }
                    else if (item is string)
                    {
                        keyValues += "::" + (string)item;
                    }
                    else
                    {
                        return null;
                    }
                }

                if (property.ValueMap != null && property.ValueMap.Count > 0)
                {
                    string text = item as string;
                    if (text == null)
                    {
                        return null;
                    }

                    string mapped;
                    copied[key] = property.ValueMap.TryGetValue(text, out mapped) ? mapped : item;
                }
                else
                {
                    copied[key] = item;
                }
            }

            foreach (KeyValuePair<string, object> entry in copied)
            {
                canonical[entry.Key] = entry.Value;
            }

            return keyValues;
        }

        private static bool IsTrue(List<string> values)
        {
            return values != null && (values.Count > 1 || (values.Count == 1 && !string.IsNullOrEmpty(values[0])));
        }

        private static bool AreAllowed(object item, List<string> allowed)
        {
            if (item == null)
            {
                return false;
            }

            Array array = item as Array;
            if (array == null)
            {
                return item is string && IsAllowed((string)item, allowed);
            }

            foreach (object element in array)
            {
                string text = element as string;
                if (text == null || !IsAllowed(text, allowed))
                {
                    return false;
                }
            }

            return true;
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

    /// <summary>Writes the property lines of a MOF instance for the value types stringify handles without PowerShell.</summary>
    public static class MofPropertyWriter
    {
        private const RegexOptions TypeNameOptions = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        private static readonly Regex ArrayTypePattern = new Regex("Array", TypeNameOptions);
        private static readonly Regex SignedPattern = new Regex("^sint[0-9]{1,2}", TypeNameOptions);
        private static readonly Regex CharPattern = new Regex("^char16", TypeNameOptions);
        private static readonly Regex UnsignedPattern = new Regex("^uint[0-9]{0,2}", TypeNameOptions);
        private static readonly Regex RealPattern = new Regex("^real32|^real64", TypeNameOptions);
        private static readonly Regex BooleanPattern = new Regex("^boolean", TypeNameOptions);
        private static readonly Regex DateTimePattern = new Regex("datetime", TypeNameOptions);
        private static readonly Regex LineBreakPattern = new Regex("\r?\n", RegexOptions.CultureInvariant);

        private enum TargetKind
        {
            Text,
            Boolean,
            Signed,
            Unsigned,
            Other,
        }

        /// <summary>Returns null when a property needs the PowerShell path.</summary>
        public static string WriteProperties(IDictionary properties, IDictionary<string, DynamicKeywordProperty> propertyTypes, IDictionary instanceAliases)
        {
            if (properties == null || properties.Count == 0 || instanceAliases == null || propertyTypes == null)
            {
                return null;
            }

            object[] keys = new object[properties.Count];
            properties.Keys.CopyTo(keys, 0);
            string[] names = new string[keys.Length];
            for (int index = 0; index < keys.Length; index++)
            {
                if (!(keys[index] is string))
                {
                    return null;
                }

                names[index] = (string)keys[index];
            }

            Array.Sort(names, keys, StringComparer.Ordinal);

            string[] lines = new string[keys.Length];
            for (int index = 0; index < keys.Length; index++)
            {
                string name = names[index];
                object value = properties[keys[index]];

                string typeName = null;
                DynamicKeywordProperty property;
                if (propertyTypes.TryGetValue(name, out property) && property != null)
                {
                    typeName = property.TypeConstraint;
                }

                if (value == null && string.Equals(typeName, "Instance", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }

                bool asArray = string.Equals(name, "DependsOn", StringComparison.OrdinalIgnoreCase)
                    || (typeName != null && ArrayTypePattern.IsMatch(typeName))
                    || (!string.IsNullOrEmpty(typeName) && typeName.EndsWith("[]", StringComparison.Ordinal));

                TargetKind kind = ResolveKind(typeName);
                if (kind == TargetKind.Other)
                {
                    return null;
                }

                string text = FormatValue(value, asArray, kind, instanceAliases);
                if (text == null)
                {
                    return null;
                }

                lines[index] = name + " = " + text + ";\n";
            }

            return string.Join(" ", lines);
        }

        private static TargetKind ResolveKind(string typeName)
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

        private static string FormatValue(object value, bool asArray, TargetKind kind, IDictionary instanceAliases)
        {
            if (value is PSObject || value is PSCredential || value is Hashtable || value is ScriptBlock)
            {
                return null;
            }

            Array array = value as Array;
            if (array != null || asArray)
            {
                if (value != null && array == null && !(value is string) && value is IEnumerable)
                {
                    return null;
                }

                List<string> parts = new List<string>();
                parts.Add("{");
                if (array != null)
                {
                    int remaining = array.Length;
                    foreach (object element in array)
                    {
                        string formatted = FormatValue(element, false, kind, instanceAliases);
                        if (formatted == null)
                        {
                            return null;
                        }

                        parts.Add("    " + formatted + (--remaining > 0 ? "," : string.Empty));
                    }
                }
                else if (value != null)
                {
                    string formatted = FormatValue(value, false, kind, instanceAliases);
                    if (formatted == null)
                    {
                        return null;
                    }

                    parts.Add("    " + formatted);
                }

                parts.Add("}");
                return string.Join("\n", parts);
            }

            switch (kind)
            {
                case TargetKind.Boolean:
                    if (value == null)
                    {
                        return "False";
                    }

                    if (value is bool)
                    {
                        return (bool)value ? "True" : "False";
                    }

                    long truth;
                    return TryReadInteger(value, out truth) ? (truth != 0 ? "True" : "False") : null;

                case TargetKind.Signed:
                    if (value == null)
                    {
                        return "0";
                    }

                    if (value is bool)
                    {
                        return (bool)value ? "1" : "0";
                    }

                    long signed;
                    return TryReadInteger(value, out signed) ? signed.ToString(CultureInfo.InvariantCulture) : null;

                case TargetKind.Unsigned:
                    if (value == null)
                    {
                        return "0";
                    }

                    if (value is bool)
                    {
                        return (bool)value ? "1" : "0";
                    }

                    if (value is ulong)
                    {
                        return ((ulong)value).ToString(CultureInfo.InvariantCulture);
                    }

                    long unsigned;
                    return TryReadInteger(value, out unsigned) && unsigned >= 0 ? unsigned.ToString(CultureInfo.InvariantCulture) : null;

                default:
                    return FormatText(value, instanceAliases);
            }
        }

        private static string FormatText(object value, IDictionary instanceAliases)
        {
            string text = value as string;
            if (text != null)
            {
                if (instanceAliases.Contains(text))
                {
                    string alias = instanceAliases[text] as string;
                    if (!string.IsNullOrEmpty(alias))
                    {
                        return text;
                    }
                }

                return Quote(text);
            }

            if (value == null)
            {
                return "NULL";
            }

            if (value is bool)
            {
                return Quote((bool)value ? "True" : "False");
            }

            long integer;
            if (value is ulong)
            {
                return Quote(((ulong)value).ToString(CultureInfo.InvariantCulture));
            }

            return TryReadInteger(value, out integer) ? Quote(integer.ToString(CultureInfo.InvariantCulture)) : null;
        }

        private static string Quote(string text)
        {
            string escaped = text.Replace("\\", "\\\\");
            escaped = LineBreakPattern.Replace(escaped, "\\n");
            escaped = escaped.Replace("\"", "\\\"");
            return "\"" + escaped + "\"";
        }

        private static bool TryReadInteger(object value, out long integer)
        {
            if (value is int)
            {
                integer = (int)value;
                return true;
            }

            if (value is long)
            {
                integer = (long)value;
                return true;
            }

            if (value is short)
            {
                integer = (short)value;
                return true;
            }

            if (value is byte)
            {
                integer = (byte)value;
                return true;
            }

            if (value is sbyte)
            {
                integer = (sbyte)value;
                return true;
            }

            if (value is ushort)
            {
                integer = (ushort)value;
                return true;
            }

            if (value is uint)
            {
                integer = (uint)value;
                return true;
            }

            integer = 0;
            return false;
        }
    }
}
