-- DimLocation
DROP TABLE IF EXISTS DimLocation;
SELECT
    ROW_NUMBER() OVER (ORDER BY zip_code_prefix) AS LocationKey,
    zip_code_prefix AS ZipCodePrefix,
    CAST(city AS VARCHAR(50)) AS City,
    CAST(state AS VARCHAR(2)) AS State,
    CAST(geolocation_state_name AS VARCHAR(50)) AS StateName,
    avg_lat AS AvgLatitude,
    avg_lng AS AvgLongitude
INTO DimLocation
FROM (
    SELECT
        geolocation_zip_code_prefix AS zip_code_prefix,
        geolocation_city AS city,
        geolocation_state AS state,
        geolocation_state_name, 
        avg_lat,
        avg_lng
    FROM lh_silver_olist.dbo.geolocation
) AS distinct_locations;

--DimCustomer
DROP TABLE IF EXISTS DimCustomer;
SELECT
    ROW_NUMBER() OVER (ORDER BY c.customer_id) AS CustomerKey,
    
    CAST(c.customer_id AS VARCHAR(32)) AS CustomerId,
    CAST(c.customer_city AS VARCHAR(50)) AS CustomerCity,
    CAST(c.customer_state AS VARCHAR(2)) AS CustomerState,
    l.StateName AS CustomerStateName,
    c.customer_zip_code_prefix AS CustomerZipCodePrefix,
    l.AvgLatitude AS CustomerLatitude,
    l.AvgLongitude AS CustomerLongitude
INTO DimCustomer
FROM (
    SELECT DISTINCT customer_id, customer_city, customer_state, customer_zip_code_prefix
    FROM lh_silver_olist.dbo.customers
) AS c
LEFT JOIN DimLocation l ON c.customer_zip_code_prefix = l.ZipCodePrefix
                        

-- DimSeller
DROP TABLE IF EXISTS DimSeller;
SELECT
    ROW_NUMBER() OVER (ORDER BY s.seller_id) AS SellerKey,

    CAST(s.seller_id AS VARCHAR(32)) AS SellerId,
    CAST(s.seller_city AS VARCHAR(50)) AS SellerCity,
    CAST(s.seller_state AS VARCHAR(2)) AS SellerState,
    l.StateName AS SellerStateName,
    s.seller_zip_code_prefix AS SellerZipCodePrefix,
    l.AvgLatitude AS SellerLatitude,
    l.AvgLongitude AS SellerLongitude
INTO DimSeller
FROM (
    SELECT DISTINCT seller_id, seller_city, seller_state, seller_zip_code_prefix
    FROM lh_silver_olist.dbo.sellers
) AS s
LEFT JOIN DimLocation l ON s.seller_zip_code_prefix = l.ZipCodePrefix
                        
-- =====================================================================
-- DimProduct (includes category-name translation as Gold business logic)
-- =====================================================================
-- Product dimension, built from the cleaned Silver products table joined
-- against the category-name translation lookup (Portuguese -> English).
--
-- The English category translation is deliberately applied here in Gold,
-- not in Silver: it's a presentation/business-logic concern specific to
-- this reporting model, not a structural data-quality fix. Following the
-- project's Silver/Gold boundary rule ("would another team with a
-- different purpose need this same transformation?") — a team consuming
-- Silver for a different purpose (e.g. logistics) would have no need for
-- English category names, so the translation belongs in Gold.
-- =====================================================================

DROP TABLE IF EXISTS DimProduct;

SELECT
    -- Surrogate key: stable, sortable integer key for the dimension,
    -- independent of the natural key (product_id).
    ROW_NUMBER() OVER (ORDER BY product_id) AS ProductKey,

    CAST(product_id AS VARCHAR(32)) AS ProductId,
    CAST(product_category AS VARCHAR(50)) AS ProductCategory,

    -- Physical attributes, used for freight/logistics analysis.
    product_weight_g AS ProductWeightG,
    product_length_cm AS ProductLengthCm,
    product_height_cm AS ProductHeightCm,
    product_width_cm AS ProductWidthCm
INTO DimProduct
FROM (
    SELECT
        p.product_id,

        -- LEFT JOIN preserves every product even if its category has no
        -- translation entry. COALESCE falls back to 'unknown' rather than
        -- NULL, so every product row always has a usable category value
        -- for grouping/filtering in the dashboards, and unmapped products
        -- surface explicitly instead of silently disappearing from
        -- category-level reports.
        COALESCE(t.product_category_name_english, 'unknown') AS product_category,

        p.product_weight_g,
        p.product_length_cm,
        p.product_height_cm,
        p.product_width_cm
    FROM lh_silver_olist.dbo.products p
    LEFT JOIN lh_silver_olist.dbo.product_category_translation t
        ON p.product_category_name = t.product_category_name
) AS product_with_category;






