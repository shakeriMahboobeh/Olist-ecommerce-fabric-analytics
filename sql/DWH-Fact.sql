/* Grain decision: kept at one row per sold item (order_id + order_item_id)
   rather than aggregating to order-item-plus-quantity, to preserve maximum
   analytical flexibility. Reports needing an aggregated view are served by
   a separate SQL view instead — this avoids data loss and duplicating the
   transformation logic. */

DROP TABLE IF EXISTS FactOrderItems;

/* Row-count analysis (111,050 / 942 / 544) confirmed a multiplicative effect
   on orders with both multiple items AND multiple reviews.
   Fix: reviews aggregated the same way as payments — one row per order,
   keeping the most recent. */
                                                                                                                                                                                                                                                                                                                        
WITH primary_review AS (
    SELECT order_id, review_score
    FROM (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_creation_date DESC) AS rn
        FROM lh_silver_olist.dbo.reviews
    ) ranked
    WHERE rn = 1
),
/* Payments are modeled as denormalized fields on FactOrderItems rather than
   a separate FactPayments table, due to a grain mismatch: a payment applies
   to a whole order, but an order can include items from multiple sellers/
   products, so there's no clean join from a payment-grain fact to
   DimSeller/DimProduct. Instead, payments are aggregated to one row per
   order here and joined into the order-item-grain fact table below.

Dominant payment type per order: an order can have multiple payment rows
   (e.g. voucher + credit card), so pick the one with the highest value as
   the representative type, using the same ROW_NUMBER pattern as reviews. */
primary_payment AS (
    SELECT order_id, payment_type
    FROM (
        SELECT order_id, payment_type,
               ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY payment_value DESC) AS rn
        FROM lh_silver_olist.dbo.payments
    ) ranked
    WHERE rn = 1
),
-- Order-level payment totals: sum of all payment rows, how many separate
-- payments were made, and the highest installment count used.
payment_summary AS (
    SELECT order_id, SUM(payment_value) AS total_payment_value,
           COUNT(*) AS payment_count, MAX(payment_installments) AS max_installments
    FROM lh_silver_olist.dbo.payments
    GROUP BY order_id
),
-- Combine the dominant type with the order-level totals into one row per
-- order, ready to join into FactOrderItems.
payments_aggregated AS (
    SELECT ps.order_id, pp.payment_type, ps.total_payment_value, ps.payment_count, ps.max_installments
    FROM payment_summary ps
    JOIN primary_payment pp ON ps.order_id = pp.order_id
)
SELECT
    dc.CustomerKey,
    ds.SellerKey,
    dp.ProductKey,
    dd.DateKey AS OrderDateKey,
    CAST(oi.order_id AS VARCHAR(32)) AS OrderId,
    CAST(oi.order_item_id AS VARCHAR(10)) AS OrderItemID,
    oi.price AS Price,
    oi.freight_value AS FreightValue,
    pr.review_score AS ReviewScore,
    pa.payment_type AS PaymentType,
    pa.total_payment_value AS TotalPaymentValue,
    pa.payment_count AS PaymentCount,
    pa.max_installments AS MaxInstallments,
    CASE WHEN o.order_delivered_customer_date IS NOT NULL THEN 1 ELSE 0 END AS IsDelivered,
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NULL
         THEN 1 ELSE 0 END AS StatusDateMismatch,
    DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date) AS DeliveryDays,
    CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
         THEN 1 ELSE 0 END AS IsLateDelivery,
    DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) AS EstimateAccuracyDays,
    CASE 
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) > 5 THEN 'Much earlier'
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) BETWEEN 1 AND 5 THEN 'Slightly earlier'
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) = 0 THEN 'Exactly on estimate'
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) BETWEEN -5 AND -1 THEN 'Slightly late'
        ELSE 'Much later'
    END AS EstimateAccuracyBucket,
    CASE 
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) > 5 THEN 1
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) BETWEEN 1 AND 5 THEN 2
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) = 0 THEN 3
        WHEN DATEDIFF(DAY, o.order_delivered_customer_date, o.order_estimated_delivery_date) BETWEEN -5 AND -1 THEN 4
        ELSE 5
    END AS BucketSortOrder
INTO FactOrderItems
FROM lh_silver_olist.dbo.order_items oi
JOIN lh_silver_olist.dbo.orders o ON oi.order_id = o.order_id
JOIN DimCustomer dc ON o.customer_id = dc.CustomerId
JOIN DimSeller ds ON oi.seller_id = ds.SellerId
JOIN DimProduct dp ON oi.product_id = dp.ProductId
JOIN DimDate dd ON CAST(o.order_purchase_timestamp AS DATE) = dd.Date
LEFT JOIN primary_review pr ON oi.order_id = pr.order_id
LEFT JOIN payments_aggregated pa ON oi.order_id = pa.order_id;
