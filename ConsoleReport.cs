using System.Globalization;
using Spectre.Console;

public static class ConsoleReport
{
    private const double HighCostThreshold = 1.0;

    public static void PrintRawPlanXml(string planXml)
    {
        AnsiConsole.Write(new Rule("[grey]Plan XML[/]").LeftJustified());
        AnsiConsole.WriteLine(planXml);
    }

    public static void PrintFindings(IReadOnlyCollection<QueryFinding> findings)
    {
        AnsiConsole.WriteLine();
        if (findings.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]¡Felicidades! No se detectaron operadores de alto riesgo.[/]");
        }
        else
        {
            var table = new Table()
                .Border(TableBorder.Rounded)
                .Expand()
                .AddColumn("Operador")
                .AddColumn("Tabla")
                .AddColumn("Filas reales")
                .AddColumn("Costo estimado");

            foreach (var finding in findings)
            {
                var color = GetColor(finding);
                var tableName = string.IsNullOrWhiteSpace(finding.TableName)
                    ? "(no identificada)"
                    : finding.TableName;

                table.AddRow(
                    new Markup($"[{color}]{Markup.Escape(finding.PhysicalOp)}[/]"),
                    new Markup($"[{color}]{Markup.Escape(tableName)}[/]"),
                    new Markup($"[{color}]{finding.TableRowCount.ToString("N0", CultureInfo.InvariantCulture)}[/]"),
                    new Markup($"[{color}]{finding.EstimatedCost.ToString("F4", CultureInfo.InvariantCulture)}[/]"));
            }

            AnsiConsole.Write(table);
        }

        var recommendations = findings
            .Where(finding => string.Equals(finding.PhysicalOp, "Table Scan", StringComparison.OrdinalIgnoreCase))
            .Select(finding =>
            {
                var tableName = string.IsNullOrWhiteSpace(finding.TableName)
                    ? "(no identificada)"
                    : finding.TableName;

                return $"Se detectó un Table Scan en la tabla {tableName} ({finding.TableRowCount.ToString("N0", CultureInfo.InvariantCulture)} filas). Considera crear un índice no-clustered en las columnas de filtro.";
            })
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        var summaryLines = new List<string>
        {
            $"Operadores de alto riesgo detectados: {findings.Count}."
        };
        summaryLines.AddRange(recommendations);

        var summary = new Panel(new Markup(string.Join(
            Environment.NewLine,
            summaryLines.Select(Markup.Escape))))
        {
            Header = new PanelHeader("Resumen"),
            Border = BoxBorder.Rounded,
            Padding = new Padding(1, 0, 1, 0),
            Expand = true
        };

        AnsiConsole.WriteLine();
        AnsiConsole.Write(summary);
    }

    private static string GetColor(QueryFinding finding)
    {
        if (string.Equals(finding.PhysicalOp, "Table Scan", StringComparison.OrdinalIgnoreCase) ||
            finding.EstimatedCost > HighCostThreshold)
        {
            return "red";
        }

        return finding.EstimatedCost > 0.1 ||
            !string.Equals(finding.PhysicalOp, "Sort", StringComparison.OrdinalIgnoreCase)
            ? "yellow"
            : "green";
    }
}
