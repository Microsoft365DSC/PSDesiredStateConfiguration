using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation.Language;
using System.Text;

namespace M365DSC.PSDesiredStateConfiguration;

/// <summary>Rewrites configuration text for the fast compilation host.</summary>
public static class FastHostTextRewriter
{
    private const string MaskedConfigurationKeyword = "C0nfiguration";

    private const string ImportKeyword = "Import-DscResource";

    /// <summary>
    /// Lists the configuration names and the <c>Import-DscResource</c> statements of a parsed script
    /// whose <c>Configuration</c> keyword is masked as <c>C0nfiguration</c>.
    /// </summary>
    /// <param name="ast">The script parsed from the masked text.</param>
    /// <returns>
    /// The name of each configuration statement, taken from its first string constant other than the
    /// masked keyword, and every <c>Import-DscResource</c> command, both in source order.
    /// </returns>
    /// <exception cref="ArgumentNullException"><paramref name="ast"/> is null.</exception>
    public static FastHostConfigurationCommands ListConfigurationCommands(Ast ast)
    {
        if (ast is null)
        {
            throw new ArgumentNullException(nameof(ast));
        }

        var configurationNames = new List<string>();
        var importStatements = new List<CommandAst>();

        foreach (CommandAst command in ast.FindAll(node => node is CommandAst, true).Cast<CommandAst>())
        {
            string? commandName = command.GetCommandName();

            if (string.Equals(commandName, MaskedConfigurationKeyword, StringComparison.OrdinalIgnoreCase))
            {
                string? name = command.CommandElements
                    .OfType<StringConstantExpressionAst>()
                    .Select(element => element.Value)
                    .FirstOrDefault(value => !string.Equals(value, MaskedConfigurationKeyword, StringComparison.OrdinalIgnoreCase));

                if (name is not null)
                {
                    configurationNames.Add(name);
                }
            }
            else if (string.Equals(commandName, ImportKeyword, StringComparison.OrdinalIgnoreCase))
            {
                importStatements.Add(command);
            }
        }

        return new FastHostConfigurationCommands(configurationNames.ToArray(), importStatements.ToArray());
    }

    /// <summary>
    /// Removes the given import statements from the text and, for every resource keyword, joins a
    /// next-line property block to its keyword and turns the block into a hashtable literal.
    /// </summary>
    /// <param name="text">The configuration text the extents of <paramref name="ast"/> refer to.</param>
    /// <param name="ast">The script parsed from the masked form of <paramref name="text"/>.</param>
    /// <param name="importStatements">The statements to remove. Null entries are skipped.</param>
    /// <param name="keywordNames">The resource keywords, compared without case. Without any, only the removal applies.</param>
    /// <param name="merge">Joins a property block that starts on the line after its keyword to that keyword.</param>
    /// <param name="convert">Prefixes each keyword's property block with <c>@</c>, so it parses as a hashtable.</param>
    /// <returns>The rewritten text, identical to <paramref name="text"/> when nothing applies.</returns>
    /// <exception cref="ArgumentNullException"><paramref name="text"/> or <paramref name="ast"/> is null.</exception>
    /// <exception cref="InvalidOperationException">Two edits overlap.</exception>
    public static string Rewrite(string text, Ast ast, Ast[]? importStatements, string[]? keywordNames, bool merge, bool convert)
    {
        if (text is null)
        {
            throw new ArgumentNullException(nameof(text));
        }

        if (ast is null)
        {
            throw new ArgumentNullException(nameof(ast));
        }

        var edits = new List<TextEdit>();

        foreach (Ast statement in (importStatements ?? Array.Empty<Ast>()).Where(statement => statement is not null))
        {
            edits.Add(new TextEdit(statement.Extent.StartOffset, statement.Extent.EndOffset - statement.Extent.StartOffset, string.Empty));
        }

        var names = new HashSet<string>((keywordNames ?? Array.Empty<string>()).Where(name => !string.IsNullOrEmpty(name)), StringComparer.OrdinalIgnoreCase);

        if (names.Count == 0 || !(merge || convert))
        {
            return ApplyEdits(text, edits);
        }

        var bodyStarts = new HashSet<int>();

        if (merge)
        {
            AddMergeEdits(text, ast, names, convert, edits, bodyStarts);
        }

        if (convert)
        {
            AddBodyEdits(text, ast, names, edits, bodyStarts);
        }

        return ApplyEdits(text, edits);
    }

    // With the keyword unknown to the parser, a next-line brace parses as a separate scriptblock
    // statement and the engine rejects the resource as undefined.
    private static void AddMergeEdits(string text, Ast ast, HashSet<string> names, bool convert, List<TextEdit> edits, HashSet<int> bodyStarts)
    {
        foreach (Ast block in ast.FindAll(node => node is StatementBlockAst || node is NamedBlockAst, true))
        {
            IReadOnlyList<StatementAst> statements = block is StatementBlockAst statementBlock
                ? statementBlock.Statements
                : ((NamedBlockAst)block).Statements;

            for (int index = 0; index < statements.Count - 1; index++)
            {
                MergeCandidate? candidate = FindMergeCandidate(statements[index]);

                if (candidate is null || string.IsNullOrEmpty(candidate.Name) || !names.Contains(candidate.Name!))
                {
                    continue;
                }

                if (statements[index + 1] is not PipelineAst second || second.PipelineElements.Count != 1 ||
                    second.PipelineElements[0] is not CommandExpressionAst expression ||
                    !(expression.Expression is ScriptBlockExpressionAst || expression.Expression is HashtableAst))
                {
                    continue;
                }

                int gapStart = candidate.EndOffset;
                int gapLength = second.Extent.StartOffset - gapStart;

                if (gapLength > 0)
                {
                    edits.Add(new TextEdit(gapStart, gapLength, " "));
                }

                if (convert && expression.Expression is ScriptBlockExpressionAst)
                {
                    int offset = second.Extent.StartOffset;

                    if (bodyStarts.Add(offset))
                    {
                        bool separated = gapLength > 0 || (offset > 0 && char.IsWhiteSpace(text[offset - 1]));
                        edits.Add(new TextEdit(offset, 0, separated ? "@" : " @"));
                    }
                }
            }
        }
    }

    private static void AddBodyEdits(string text, Ast ast, HashSet<string> names, List<TextEdit> edits, HashSet<int> bodyStarts)
    {
        foreach (CommandAst command in ast.FindAll(node => node is CommandAst, true).Cast<CommandAst>())
        {
            IReadOnlyList<CommandElementAst> elements = command.CommandElements;

            if (elements[elements.Count - 1] is not ScriptBlockExpressionAst body)
            {
                continue;
            }

            string? name = FindBodyKeywordName(command);

            if (string.IsNullOrEmpty(name) || !names.Contains(name!))
            {
                continue;
            }

            int offset = body.Extent.StartOffset;

            // 'MSFT_Type @{' parses and 'MSFT_Type@{' does not.
            if (bodyStarts.Add(offset))
            {
                bool separated = offset == 0 || char.IsWhiteSpace(text[offset - 1]);
                edits.Add(new TextEdit(offset, 0, separated ? "@" : " @"));
            }
        }
    }

    // A keyword a next-line brace belongs to has one of two shapes:
    //   KeywordName [InstanceName]        - a resource statement
    //   PropertyName = KeywordName        - a nested CIM instance inside a resource body
    // The second is no assignment. Inside a configuration body the bare property name makes the
    // parser produce one command whose elements are the property name, a literal '=' and the keyword.
    private static MergeCandidate? FindMergeCandidate(StatementAst statement)
    {
        PipelineAst? pipeline = statement as PipelineAst ?? (statement as AssignmentStatementAst)?.Right as PipelineAst;

        if (pipeline is null || pipeline.PipelineElements.Count != 1 || pipeline.PipelineElements[0] is not CommandAst command)
        {
            return null;
        }

        IReadOnlyList<CommandElementAst> elements = command.CommandElements;

        if (elements.Count <= 2)
        {
            return new MergeCandidate(command.GetCommandName(), command.Extent.EndOffset);
        }

        if (elements.Count <= 4 && elements[1].Extent.Text == "=")
        {
            return elements[2] is StringConstantExpressionAst keyword
                ? new MergeCandidate(keyword.Value, command.Extent.EndOffset)
                : null;
        }

        return null;
    }

    private static string? FindBodyKeywordName(CommandAst command)
    {
        IReadOnlyList<CommandElementAst> elements = command.CommandElements;

        if (elements.Count >= 3 && elements[1].Extent.Text == "=")
        {
            return (elements[2] as StringConstantExpressionAst)?.Value;
        }

        return command.GetCommandName();
    }

    private static string ApplyEdits(string text, List<TextEdit> edits)
    {
        if (edits.Count == 0)
        {
            return text;
        }

        var builder = new StringBuilder(text.Length + (edits.Count * 2));
        int position = 0;

        foreach (TextEdit edit in edits.OrderBy(edit => edit.Start).ThenBy(edit => edit.Length))
        {
            if (edit.Start < position)
            {
                throw new InvalidOperationException($"Overlapping text edits at offset {edit.Start}.");
            }

            builder.Append(text, position, edit.Start - position).Append(edit.Text);
            position = edit.Start + edit.Length;
        }

        return builder.Append(text, position, text.Length - position).ToString();
    }

    private sealed class TextEdit
    {
        public TextEdit(int start, int length, string text)
        {
            Start = start;
            Length = length;
            Text = text;
        }

        public int Start { get; }

        public int Length { get; }

        public string Text { get; }
    }

    private sealed class MergeCandidate
    {
        public MergeCandidate(string? name, int endOffset)
        {
            Name = name;
            EndOffset = endOffset;
        }

        public string? Name { get; }

        public int EndOffset { get; }
    }
}

/// <summary>The configuration names and resource imports of a parsed configuration script.</summary>
public sealed class FastHostConfigurationCommands
{
    /// <summary>Creates the result of <see cref="FastHostTextRewriter.ListConfigurationCommands"/>.</summary>
    /// <param name="configurationNames">The name of each configuration statement, in source order.</param>
    /// <param name="importStatements">Every <c>Import-DscResource</c> command, in source order.</param>
    public FastHostConfigurationCommands(string[] configurationNames, CommandAst[] importStatements)
    {
        ConfigurationNames = configurationNames;
        ImportStatements = importStatements;
    }

    /// <summary>Gets the name of each configuration statement, in source order.</summary>
    public string[] ConfigurationNames { get; }

    /// <summary>Gets every <c>Import-DscResource</c> command, in source order.</summary>
    public CommandAst[] ImportStatements { get; }
}
