using System.CommandLine;
using Microsoft.Data.SqlClient;
using Spectre.Console;

var connectionStringOption = new Option<string>("--connection", ["-c"])
{
    Description = "Cadena de conexión a SQL Server",
    Required = true
};
var queryOption = new Option<string>("--query", ["-q"])
{
    Description = "Comando SQL o EXEC de SP a analizar",
    Required = true
};
var showPlanOption = new Option<bool>("--show-plan")
{
    Description = "Imprime el XML crudo del plan de ejecución"
};

var rootCommand = new RootCommand("Analiza el plan de ejecución de una consulta en SQL Server")
{
    connectionStringOption,
    queryOption,
    showPlanOption
};

rootCommand.SetAction(async parseResult =>
{
    var connectionString = parseResult.GetRequiredValue(connectionStringOption);
    var query = parseResult.GetRequiredValue(queryOption);
    var showPlan = parseResult.GetValue(showPlanOption);

    try
    {
        var planXml = await SqlQueryProfiler.CapturePlanAsync(connectionString, query);
        if (showPlan)
        {
            ConsoleReport.PrintRawPlanXml(planXml);
        }

        var findings = QueryPlanAnalyzer.Analyze(planXml);
        await SqlQueryProfiler.PopulateTableRowCountsAsync(findings, connectionString);
        ConsoleReport.PrintFindings(findings);
        return 0;
    }
    catch (SqlException exception)
    {
        AnsiConsole.MarkupLine($"[red]Error de SQL Server:[/] {Markup.Escape(exception.Message)}");
        return 1;
    }
    catch (InvalidOperationException exception)
    {
        AnsiConsole.MarkupLine($"[red]No se pudo analizar la consulta:[/] {Markup.Escape(exception.Message)}");
        return 1;
    }
    catch (System.Xml.XmlException exception)
    {
        AnsiConsole.MarkupLine($"[red]El plan de ejecución contiene XML inválido:[/] {Markup.Escape(exception.Message)}");
        return 1;
    }
});

return await rootCommand.Parse(args).InvokeAsync();
