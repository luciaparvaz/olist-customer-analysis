-- =============================================================
-- Phase 3 CRISP-DM — Data Preparation
-- Project: Customer Behavior Analysis — Olist Brazilian E-Commerce
-- Goal: Build an order_id-level master table with clean variables
--       and business features ready for modeling.
-- =============================================================


-- -------------------------------------------------------------
-- CTE 1: delivered_orders
-- Base of the analysis: only orders with status 'delivered'.
-- We exclude cancelled, in-transit or incident orders because
-- they have no real delivery date to compute the delay from.
-- -------------------------------------------------------------
WITH delivered_orders AS (
    SELECT
        order_id,
        customer_id,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date,      -- actual delivery date to the customer
        order_estimated_delivery_date       -- date promised to the customer
    FROM orders
    WHERE order_status = 'delivered'        -- focus on completed orders
      AND order_delivered_customer_date IS NOT NULL   -- ensure a real date is available
      AND order_estimated_delivery_date IS NOT NULL   -- ensure a promised date is available
),

-- -------------------------------------------------------------
-- CTE 2: items_aggregated
-- order_items has one row per item within the order.
-- We aggregate to order_id level to enable a 1-to-1 join.
-- We compute total value, total freight and number of items.
-- -------------------------------------------------------------
items_aggregated AS (
    SELECT
        order_id,
        COUNT(order_item_id)        AS n_items,         -- how many distinct products in the order
        SUM(price)                  AS price_total,     -- sum of prices excluding freight
        SUM(freight_value)          AS freight_total,   -- total logistics cost
        MIN(seller_id)              AS seller_id,       -- main seller (first item)
        MIN(product_id)             AS product_id       -- main product (first item)
    FROM order_items
    GROUP BY order_id
),

-- -------------------------------------------------------------
-- CTE 3: reviews_per_order
-- In theory there is one review per order, but duplicates exist
-- (99,224 rows in order_reviews over 98,673 unique order_id).
-- FIXED (portfolio review, priority 5): the previous filter
-- ("WHERE review_id IN (SELECT MAX(review_id) ... GROUP BY order_id)")
-- had two bugs: (a) review_id is a hash, MAX() is lexicographic
-- order, not "the most recent one"; (b) the IN is not correlated
-- with order_id, so more than one row per order could survive if
-- two different order_id share the same global MAX(review_id)
-- (doesn't happen here, but the filter doesn't guarantee it).
-- Replaced with ROW_NUMBER partitioned by order_id, ordered by the
-- actual review_answer_timestamp, with an explicit tiebreak on
-- review_id for determinism.
-- review_creation_date/review_answer_timestamp are kept (previously
-- dropped in notebook 02) so notebook 03 can check whether the
-- review was written before or after the actual order delivery
-- (possible temporal leakage in the negative-review driver analysis).
-- -------------------------------------------------------------
reviews_deduped AS (
    SELECT
        order_id,
        review_score,
        review_creation_date,
        review_answer_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_answer_timestamp DESC, review_id DESC
        ) AS rn
    FROM order_reviews
),
reviews_per_order AS (
    SELECT
        order_id,
        review_score,
        review_creation_date,
        review_answer_timestamp,
        -- Negative review flag: scores 1 and 2 indicate clear dissatisfaction.
        -- Score 3 is neutral and is excluded from the negative flag.
        CASE WHEN review_score <= 2 THEN 1 ELSE 0 END  AS is_negative_review
    FROM reviews_deduped
    WHERE rn = 1
),

-- -------------------------------------------------------------
-- CTE 4: customer_info
-- Customer data: we use customer_unique_id to identify the actual
-- customer over time (customer_id changes per order).
-- -------------------------------------------------------------
customer_info AS (
    SELECT
        customer_id,
        customer_unique_id,     -- stable customer ID (for RFM analysis)
        customer_city,
        customer_state
    FROM customers
),

-- -------------------------------------------------------------
-- CTE 5: product_categories
-- Joins products with the English category translation.
-- Products without a category (NULL) are flagged as 'unknown'.
-- -------------------------------------------------------------
product_categories AS (
    SELECT
        p.product_id,
        COALESCE(t.product_category_name_english, 'unknown') AS category_en,
        p.product_weight_g
    FROM products p
    LEFT JOIN category_translation t
        ON p.product_category_name = t.product_category_name
    -- LEFT JOIN so we don't lose products with no assigned category
),

-- -------------------------------------------------------------
-- CTE 6: master_table
-- Central join: brings together all the CTEs above around the order.
-- Computes the final business features.
-- -------------------------------------------------------------
master_table AS (
    SELECT
        -- Identifiers
        o.order_id,
        c.customer_unique_id,
        c.customer_state,
        c.customer_city,
        pc.category_en,

        -- Temporality: useful for seasonality and trends
        o.order_purchase_timestamp,
        STRFTIME('%Y-%m', o.order_purchase_timestamp)   AS order_month,     -- purchase month
        STRFTIME('%w',   o.order_purchase_timestamp)    AS order_weekday,   -- weekday (0=Sun)

        -- Delivery metrics
        JULIANDAY(o.order_delivered_customer_date)
            - JULIANDAY(o.order_purchase_timestamp)     AS delivery_days,   -- total days purchase -> delivery

        -- Main feature: actual delay vs. promise.
        -- Positive = delivered late (bad experience).
        -- Negative = delivered earlier than promised (good experience).
        JULIANDAY(o.order_delivered_customer_date)
            - JULIANDAY(o.order_estimated_delivery_date) AS delivery_delay_days,

        -- Economic metrics
        i.n_items,
        i.price_total,
        i.freight_total,
        -- Freight/price ratio: signals whether the customer paid a lot on logistics
        ROUND(i.freight_total * 1.0 / NULLIF(i.price_total, 0), 4) AS freight_ratio,

        -- Customer satisfaction
        r.review_score,
        r.is_negative_review,
        -- Kept (previously dropped) so we can check whether the review was
        -- written before or after the actual delivery (possible temporal
        -- leakage in the Phase 4 / notebook 03 driver analysis).
        r.review_creation_date,
        r.review_answer_timestamp,
        CASE WHEN r.review_creation_date IS NOT NULL
                  AND r.review_creation_date < o.order_delivered_customer_date
             THEN 1 ELSE 0 END AS review_before_delivery,

        -- Product weight (proxy for package category/size)
        pc.product_weight_g

    FROM delivered_orders o
    -- JOIN with items: every delivered order must have items
    INNER JOIN items_aggregated i
        ON o.order_id = i.order_id
    -- JOIN with the main item's product/category
    LEFT JOIN product_categories pc
        ON i.product_id = pc.product_id
    -- LEFT JOIN with reviews: not every order has a review
    LEFT JOIN reviews_per_order r
        ON o.order_id = r.order_id
    -- INNER JOIN with customers: every order must have a customer
    INNER JOIN customer_info c
        ON o.customer_id = c.customer_id
)

-- =============================================================
-- Final result: master table ready for modeling.
-- Filter delivery_days > 0 to drop corrupt records
-- (orders where the delivery date is before the purchase date).
-- =============================================================
SELECT *
FROM master_table
WHERE delivery_days > 0
ORDER BY order_purchase_timestamp;
