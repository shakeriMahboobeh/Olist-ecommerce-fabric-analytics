-- Consolidated data quality gate: ~20 checks (UNION ALL) covering referential
-- integrity, key uniqueness, plausibility, and cross-table consistency.
-- Each check is tagged "Should be 0" (critical) or a documented, accepted
-- pattern/gap (see README) — this distinguishes real defects from known,
-- explained data limitations.
--
-- IsCritical flags rows that should be 0 but aren't. If any critical check
-- fails, THROW converts it into a real pipeline failure (rather than a
-- silently-successful script), which the orchestrating pipeline uses to
-- trigger the on-failure email alert before bad data reaches the
-- semantic model or dashboards.
DROP TABLE IF EXISTS #DQResults;

SELECT 
    CheckName, 
    ResultCount, 
    Expected,
    CASE WHEN Expected = 'Should be 0' AND ResultCount > 0 THEN 1 ELSE 0 END AS IsCritical
INTO #DQResults
FROM (
    SELECT 'Orphan Customers' AS CheckName, 
        (SELECT COUNT(*) FROM FactOrderItems f LEFT JOIN DimCustomer dc ON f.CustomerKey = dc.CustomerKey WHERE dc.CustomerKey IS NULL) AS ResultCount,
        'Should be 0' AS Expected
    UNION ALL
    SELECT 'Orphan Sellers', 
        (SELECT COUNT(*) FROM FactOrderItems f LEFT JOIN DimSeller ds ON f.SellerKey = ds.SellerKey WHERE ds.SellerKey IS NULL),
        'Should be 0'
    UNION ALL
    SELECT 'Orphan Products', 
        (SELECT COUNT(*) FROM FactOrderItems f LEFT JOIN DimProduct dp ON f.ProductKey = dp.ProductKey WHERE dp.ProductKey IS NULL),
        'Should be 0'
    UNION ALL
    SELECT 'Orphan Dates', 
        (SELECT COUNT(*) FROM FactOrderItems f LEFT JOIN DimDate dd ON f.OrderDateKey = dd.DateKey WHERE dd.DateKey IS NULL),
        'Should be 0'
    UNION ALL
    SELECT 'Duplicate CustomerKeys', 
        (SELECT COUNT(*) FROM (SELECT CustomerKey FROM DimCustomer GROUP BY CustomerKey HAVING COUNT(*) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Duplicate SellerKeys', 
        (SELECT COUNT(*) FROM (SELECT SellerKey FROM DimSeller GROUP BY SellerKey HAVING COUNT(*) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Duplicate ProductKeys', 
        (SELECT COUNT(*) FROM (SELECT ProductKey FROM DimProduct GROUP BY ProductKey HAVING COUNT(*) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Duplicate DateKeys', 
        (SELECT COUNT(*) FROM (SELECT DateKey FROM DimDate GROUP BY DateKey HAVING COUNT(*) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Duplicate ZipCodePrefix in DimLocation', 
        (SELECT COUNT(*) FROM (SELECT ZipCodePrefix FROM DimLocation GROUP BY ZipCodePrefix HAVING COUNT(*) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Implausible Values (negative price/freight/payment)', 
        (SELECT COUNT(*) FROM FactOrderItems WHERE Price < 0 OR FreightValue < 0 OR TotalPaymentValue < 0),
        'Should be 0'
    UNION ALL
    SELECT 'Invalid Review Scores (outside 1-5)', 
        (SELECT COUNT(*) FROM FactOrderItems WHERE ReviewScore IS NOT NULL AND (ReviewScore < 1 OR ReviewScore > 5)),
        'Should be 0'
    UNION ALL
    SELECT 'Negative Delivery Days', 
        (SELECT COUNT(*) FROM FactOrderItems WHERE DeliveryDays < 0),
        'Should be 0'
    UNION ALL
    SELECT 'Fact vs OrderItems Row Count Mismatch', 
        (SELECT ABS((SELECT COUNT(*) FROM FactOrderItems) - (SELECT COUNT(*) FROM lh_silver_olist.dbo.order_items))),
        'Should be 0'
    UNION ALL
    SELECT 'Multiple Review Scores per OrderId', 
        (SELECT COUNT(*) FROM (SELECT OrderId FROM FactOrderItems WHERE ReviewScore IS NOT NULL GROUP BY OrderId HAVING COUNT(DISTINCT ReviewScore) > 1) x),
        'Should be 0'
    UNION ALL
    SELECT 'Customers without Geo Coordinates', 
        (SELECT COUNT(*) FROM DimCustomer WHERE CustomerLatitude IS NULL OR CustomerLongitude IS NULL),
        'Known gap - see README'
    UNION ALL
    SELECT 'Sellers without Geo Coordinates', 
        (SELECT COUNT(*) FROM DimSeller WHERE SellerLatitude IS NULL OR SellerLongitude IS NULL),
        'Known gap - see README (134 expected)'
    UNION ALL
    SELECT 'Customer Coordinates Outside Brazil Range', 
        (SELECT COUNT(*) FROM DimCustomer WHERE CustomerLatitude NOT BETWEEN -35 AND 6 OR CustomerLongitude NOT BETWEEN -75 AND -30),
        'Known gap - see README (4 expected)'
    UNION ALL
    SELECT 'Seller Coordinates Outside Brazil Range', 
        (SELECT COUNT(*) FROM DimSeller WHERE SellerLatitude NOT BETWEEN -35 AND 6 OR SellerLongitude NOT BETWEEN -75 AND -30),
        'Known gap - see README'
    UNION ALL
    SELECT 'Payment/Item Value Discrepancy (Orders)', 
        (SELECT COUNT(*) FROM (
            SELECT OrderId, SUM(Price + FreightValue) AS calc_total, MAX(TotalPaymentValue) AS paid_total
            FROM FactOrderItems GROUP BY OrderId
            HAVING ABS(SUM(Price + FreightValue) - MAX(TotalPaymentValue)) > 0.01
        ) x),
        'Known pattern - see README (379 expected)'
    UNION ALL
    SELECT 'Late Delivery Rate (%)', 
        (SELECT ROUND(100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM FactOrderItems WHERE IsDelivered = 1), 0), 2) FROM FactOrderItems WHERE IsLateDelivery = 1),
        'Monitoring metric, not pass/fail'
) AS AllChecks;

DECLARE @FailedChecks VARCHAR(MAX);
DECLARE @FailCount INT;

SELECT @FailCount = COUNT(*), 
       @FailedChecks = STRING_AGG(CheckName + ' (' + CAST(ResultCount AS VARCHAR(20)) + ')', ', ')
FROM #DQResults
WHERE IsCritical = 1;

IF @FailCount > 0
BEGIN
    DECLARE @ErrorMsg VARCHAR(MAX) = 'Data Quality Check FAILED. ' + CAST(@FailCount AS VARCHAR(10)) + ' critical check(s) failed: ' + @FailedChecks;
    THROW 50001, @ErrorMsg, 1;
END

SELECT CheckName, ResultCount, Expected FROM #DQResults ORDER BY CheckName;