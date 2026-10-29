using System.Data;
using System.Data.SqlTypes;
using Microsoft.Data.SqlClient;
using System.Xml;
using System.Xml.Linq;

public static class SqlQueryProfiler
{
    public static async Task<string> CapturePlanAsync(
        string connectionString,
        string query,
        CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        string? planXml = null;
        var resultSetDescriptions = new List<string>();
        try
        {
            await using var queryCommand = new SqlCommand(
                $"SET STATISTICS XML ON;{Environment.NewLine}{query}",
                connection);
            await using var reader = await queryCommand.ExecuteReaderAsync(
                CommandBehavior.SequentialAccess,
                cancellationToken);

            do
            {
                if (reader.FieldCount == 0)
                {
                    continue;
                }

                var xmlColumns = Enumerable.Range(0, reader.FieldCount)
                    .Where(column =>
                        string.Equals(reader.GetDataTypeName(column), "xml", StringComparison.OrdinalIgnoreCase) ||
                        reader.GetName(column).Contains("Showplan", StringComparison.OrdinalIgnoreCase))
                    .ToArray();

                resultSetDescriptions.Add(string.Join(
                    ", ",
                    Enumerable.Range(0, reader.FieldCount)
                        .Select(column => $"{reader.GetName(column)} ({reader.GetDataTypeName(column)})")));

                while (await reader.ReadAsync(cancellationToken))
                {
                    foreach (var column in xmlColumns)
                    {
                        if (reader.IsDBNull(column))
                        {
                            continue;
                        }

                        var value = reader.GetValue(column);
                        var xml = value is SqlXml sqlXml
                            ? sqlXml.Value
                            : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);

                        if (!string.IsNullOrWhiteSpace(xml) && IsShowPlanXml(xml))
                        {
                            planXml = xml;
                        }
                    }
                }
            }
            while (await reader.NextResultAsync(cancellationToken));
        }
        finally
        {
            await using var statisticsCommand = new SqlCommand("SET STATISTICS XML OFF;", connection);
            await statisticsCommand.ExecuteNonQueryAsync(CancellationToken.None);
        }

        return planXml ?? throw new InvalidOperationException(
            resultSetDescriptions.Count == 0
                ? "SQL Server no devolvió conjuntos de resultados. Verifica que la consulta ejecute una instrucción y que la instancia admita SET STATISTICS XML."
                : $"SQL Server devolvió resultados, pero no incluyó un plan Showplan XML. Conjuntos recibidos: {string.Join("; ", resultSetDescriptions)}. Consultas constantes como SELECT 1 pueden no generar un plan; prueba con una consulta sobre una tabla.");
    }

    private static bool IsShowPlanXml(string xml)
    {
        try
        {
            return XDocument.Parse(xml).Root?.Name.LocalName == "ShowPlanXML";
        }
        catch (XmlException)
        {
            return false;
        }
    }

    public static async Task PopulateTableRowCountsAsync(
        IEnumerable<QueryFinding> findings,
        string connectionString,
        CancellationToken cancellationToken = default)
    {
        var tableNames = findings
            .Where(finding => !string.IsNullOrWhiteSpace(finding.TableName))
            .Select(finding => finding.TableName)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (tableNames.Length == 0)
        {
            return;
        }

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        const string rowCountQuery = """
            SELECT COALESCE(SUM(row_count), 0)
            FROM sys.dm_db_partition_stats
            WHERE object_id = OBJECT_ID(@TableName)
              AND index_id < 2;
            """;

        var rowCounts = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var tableName in tableNames)
        {
            await using var command = new SqlCommand(rowCountQuery, connection);
            command.Parameters.Add("@TableName", SqlDbType.NVarChar, 776).Value = tableName;

            var result = await command.ExecuteScalarAsync(cancellationToken);
            rowCounts[tableName] = result is null or DBNull ? 0 : Convert.ToInt64(result);
        }

        foreach (var finding in findings)
        {
            if (rowCounts.TryGetValue(finding.TableName, out var rowCount))
            {
                finding.TableRowCount = rowCount;
            }
        }
    }
}
