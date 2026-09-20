/*
    Deterministic seed data. Row counts and checksums are the evidence the
    pipeline compares after migration, so the data has to be reproducible:
    a random seed would make a parity failure indistinguishable from noise.
*/
USE AppDb;
GO
SET NOCOUNT ON;

;WITH n AS (
    SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.Customers (Name, Email, Country, CreatedUtc)
SELECT  CONCAT(N'Customer ', i),
        CONCAT(N'customer', i, N'@example.invalid'),
        CASE i % 5 WHEN 0 THEN N'US' WHEN 1 THEN N'GB' WHEN 2 THEN N'DE' WHEN 3 THEN N'CA' ELSE N'AU' END,
        DATEADD(DAY, -(i % 900), CAST('2026-01-01T00:00:00' AS DATETIME2(3)))
FROM n;

;WITH n AS (
    SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects
)
INSERT dbo.Products (Sku, Name, UnitPrice, Notes)
SELECT  CONCAT('SKU-', RIGHT(CONCAT('0000', i), 4)),
        CONCAT(N'Product ', i),
        CAST((i * 7 % 500) + 4.99 AS DECIMAL(10,2)),
        CASE WHEN i % 10 = 0 THEN CAST(N'Legacy note stored in a deprecated type.' AS NTEXT) ELSE NULL END
FROM n;

;WITH n AS (
    SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.Orders (CustomerId, PlacedUtc, Status)
SELECT  ((i - 1) % 500) + 1,
        DATEADD(HOUR, -(i % 8000), CAST('2026-02-01T00:00:00' AS DATETIME2(3))),
        CASE i % 4 WHEN 0 THEN 'placed' WHEN 1 THEN 'shipped' WHEN 2 THEN 'delivered' ELSE 'cancelled' END
FROM n;

;WITH n AS (
    SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.OrderItems (OrderId, ProductId, Quantity, UnitPrice)
SELECT  ((i - 1) % 2000) + 1,
        ((i * 3 - 1) % 120) + 1,
        (i % 5) + 1,
        CAST((i * 11 % 400) + 2.50 AS DECIMAL(10,2))
FROM n;

;WITH n AS (
    SELECT TOP (300) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects
)
INSERT dbo.AuditLog (OccurredUtc, Actor, Action)
SELECT  DATEADD(MINUTE, -(i * 17), CAST('2026-02-01T00:00:00' AS DATETIME2(3))),
        CONCAT(N'svc-', i % 7),
        CASE i % 3 WHEN 0 THEN N'login' WHEN 1 THEN N'export' ELSE N'update' END
FROM n;
GO

SELECT 'Customers' AS TableName, COUNT(*) AS Rows FROM dbo.Customers
UNION ALL SELECT 'Products',  COUNT(*) FROM dbo.Products
UNION ALL SELECT 'Orders',    COUNT(*) FROM dbo.Orders
UNION ALL SELECT 'OrderItems',COUNT(*) FROM dbo.OrderItems
UNION ALL SELECT 'AuditLog',  COUNT(*) FROM dbo.AuditLog;
GO
