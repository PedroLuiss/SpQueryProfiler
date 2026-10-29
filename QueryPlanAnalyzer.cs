using System.Globalization;
using System.Xml.Linq;

public static class QueryPlanAnalyzer
{
    private static readonly HashSet<string> RiskyOperators = new(StringComparer.OrdinalIgnoreCase)
    {
        "Table Scan",
        "Clustered Index Scan",
        "Key Lookup",
        "Sort"
    };

    private static readonly XNamespace ShowPlanNamespace =
        "http://schemas.microsoft.com/sqlserver/2004/07/showplan";

    public static List<QueryFinding> Analyze(string planXml)
    {
        var document = XDocument.Parse(planXml);

        return document
            .Descendants(ShowPlanNamespace + "RelOp")
            .Where(relOp => RiskyOperators.Contains((string?)relOp.Attribute("PhysicalOp") ?? string.Empty))
            .Select(relOp =>
            {
                var tableObject = relOp
                    .Descendants(ShowPlanNamespace + "Object")
                    .FirstOrDefault();

                return new QueryFinding
                {
                    PhysicalOp = (string?)relOp.Attribute("PhysicalOp") ?? "Desconocido",
                    TableName = GetTableName(tableObject),
                    EstimatedRows = ParseNumber((string?)relOp.Attribute("EstimateRows")),
                    EstimatedCost = ParseNumber((string?)relOp.Attribute("EstimatedTotalSubtreeCost"))
                };
            })
            .ToList();
    }

    private static double ParseNumber(string? value) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : 0;

    private static string GetTableName(XElement? tableObject)
    {
        if (tableObject is null)
        {
            return string.Empty;
        }

        var database = (string?)tableObject.Attribute("Database");
        var schema = (string?)tableObject.Attribute("Schema");
        var table = (string?)tableObject.Attribute("Table");

        if (string.IsNullOrWhiteSpace(table))
        {
            return string.Empty;
        }

        var parts = new List<string>(3);
        if (!string.IsNullOrWhiteSpace(database))
        {
            parts.Add(QuoteIdentifier(database));
        }

        if (!string.IsNullOrWhiteSpace(schema))
        {
            parts.Add(QuoteIdentifier(schema));
        }

        parts.Add(QuoteIdentifier(table));
        return string.Join(".", parts);
    }

    private static string QuoteIdentifier(string value)
    {
        var identifier = value.Trim();
        if (identifier.Length >= 2 && identifier[0] == '[' && identifier[^1] == ']')
        {
            identifier = identifier[1..^1].Replace("]]", "]");
        }

        return $"[{identifier.Replace("]", "]]")}]";
    }
}
