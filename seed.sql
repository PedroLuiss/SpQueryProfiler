IF DB_ID(N'SpQueryProfilerDemo') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE [SpQueryProfilerDemo]');
END
GO

USE [SpQueryProfilerDemo];
GO

IF OBJECT_ID(N'dbo.Orders', N'U') IS NOT NULL
BEGIN
    DROP TABLE dbo.Orders;
END
GO

CREATE TABLE dbo.Orders
(
    Id int IDENTITY(1, 1) NOT NULL,
    CustomerId int NOT NULL,
    OrderDate date NOT NULL,
    Status varchar(20) NOT NULL,
    Total decimal(12, 2) NOT NULL
);
GO

WITH Digits AS
(
    SELECT value
    FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS d(value)
),
Numbers AS
(
    SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Number
    FROM Digits AS d1
    CROSS JOIN Digits AS d2
    CROSS JOIN Digits AS d3
    CROSS JOIN Digits AS d4
    CROSS JOIN Digits AS d5
)
INSERT INTO dbo.Orders (CustomerId, OrderDate, Status, Total)
SELECT
    CONVERT(int, ((Number - 1) % 1000) + 1),
    DATEADD(day, -CONVERT(int, Number % 3650), CONVERT(date, GETDATE())),
    CASE Number % 3
        WHEN 0 THEN 'Pending'
        WHEN 1 THEN 'Shipped'
        ELSE 'Cancelled'
    END,
    CONVERT(decimal(12, 2), ((Number * 137) % 500000) / 100.0)
FROM Numbers;
GO

CREATE OR ALTER PROCEDURE dbo.GetOrdersByCustomer
    @CustomerId int,
    @Status varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, CustomerId, OrderDate, Status, Total
    FROM dbo.Orders
    WHERE CustomerId = @CustomerId
      AND Status = @Status;
END
GO
