public sealed class QueryFinding
{
    public string PhysicalOp { get; set; } = string.Empty;

    public string TableName { get; set; } = string.Empty;

    public double EstimatedRows { get; set; }

    public double EstimatedCost { get; set; }

    public long TableRowCount { get; set; }
}
