/*
    The source database, standing in for something that already exists
    somewhere else. It is deliberately imperfect: real databases being
    migrated always are, and an assessment that finds nothing proves nothing.
*/
IF DB_ID('AppDb') IS NULL
    CREATE DATABASE AppDb;
GO
USE AppDb;
GO

CREATE TABLE dbo.Customers (
    CustomerId   INT IDENTITY(1,1) CONSTRAINT PK_Customers PRIMARY KEY,
    Name         NVARCHAR(120)  NOT NULL,
    Email        NVARCHAR(200)  NOT NULL,
    Country      NVARCHAR(60)   NOT NULL,
    CreatedUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_Customers_Created DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.Products (
    ProductId    INT IDENTITY(1,1) CONSTRAINT PK_Products PRIMARY KEY,
    Sku          VARCHAR(32)    NOT NULL CONSTRAINT UQ_Products_Sku UNIQUE,
    Name         NVARCHAR(160)  NOT NULL,
    UnitPrice    DECIMAL(10,2)  NOT NULL,
    -- NTEXT is deprecated and has been since 2005. The assessment reports it.
    Notes        NTEXT          NULL
);
GO

CREATE TABLE dbo.Orders (
    OrderId      INT IDENTITY(1,1) CONSTRAINT PK_Orders PRIMARY KEY,
    CustomerId   INT            NOT NULL CONSTRAINT FK_Orders_Customers REFERENCES dbo.Customers(CustomerId),
    PlacedUtc    DATETIME2(3)   NOT NULL,
    Status       VARCHAR(20)    NOT NULL
);
GO

CREATE TABLE dbo.OrderItems (
    OrderItemId  INT IDENTITY(1,1) CONSTRAINT PK_OrderItems PRIMARY KEY,
    OrderId      INT            NOT NULL CONSTRAINT FK_OrderItems_Orders REFERENCES dbo.Orders(OrderId),
    ProductId    INT            NOT NULL CONSTRAINT FK_OrderItems_Products REFERENCES dbo.Products(ProductId),
    Quantity     INT            NOT NULL,
    UnitPrice    DECIMAL(10,2)  NOT NULL
);
GO

/*
    A heap: no clustered index. Valid, and a common find in older estates.
    The assessment reports it rather than silently carrying it across.
*/
CREATE TABLE dbo.AuditLog (
    EventId      UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_AuditLog_Id DEFAULT NEWID(),
    OccurredUtc  DATETIME2(3)     NOT NULL,
    Actor        NVARCHAR(120)    NOT NULL,
    Action       NVARCHAR(200)    NOT NULL
);
GO

CREATE INDEX IX_Orders_CustomerId ON dbo.Orders(CustomerId);
CREATE INDEX IX_OrderItems_OrderId ON dbo.OrderItems(OrderId);
GO

CREATE VIEW dbo.vOrderTotals
AS
SELECT  o.OrderId,
        o.CustomerId,
        o.PlacedUtc,
        SUM(oi.Quantity * oi.UnitPrice) AS OrderTotal
FROM    dbo.Orders o
JOIN    dbo.OrderItems oi ON oi.OrderId = o.OrderId
GROUP BY o.OrderId, o.CustomerId, o.PlacedUtc;
GO

CREATE PROCEDURE dbo.GetCustomerOrders
    @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OrderId, PlacedUtc, OrderTotal
    FROM   dbo.vOrderTotals
    WHERE  CustomerId = @CustomerId
    ORDER BY PlacedUtc DESC;
END;
GO
