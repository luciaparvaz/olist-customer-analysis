-- =============================================================
-- Phase 4 CRISP-DM — Modeling: Customer Retention Analysis
-- Project: Customer Behavior Analysis — Olist Brazilian E-Commerce
-- Goal: Identify repeat customers, compute the retention rate per
--       category and rank categories by their ability to retain
--       customers.
-- Note: uses customer_unique_id (stable ID across orders) instead
--       of customer_id (changes per order in the Olist dataset).
-- =============================================================


-- -------------------------------------------------------------
-- CTE 1: all_customer_orders
-- Joins orders with customers to get the stable customer ID
-- (customer_unique_id) and the date of each order.
-- Only delivered orders are included: same logic as the model.
-- -------------------------------------------------------------
WITH all_customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        o.order_status
    FROM orders o
    INNER JOIN customers c
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'      -- focus on completed orders
),

-- -------------------------------------------------------------
-- CTE 2: order_sequence
-- Assigns a chronological order number to each order per customer.
-- ROW_NUMBER() lets us identify the first purchase (rn=1) and
-- subsequent purchases (rn>1) for each customer.
-- -------------------------------------------------------------
order_sequence AS (
    SELECT
        customer_unique_id,
        order_id,
        order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id          -- resets the counter per customer
            ORDER BY order_purchase_timestamp ASC    -- orders chronologically
        ) AS purchase_rank,
        COUNT(order_id) OVER (
            PARTITION BY customer_unique_id          -- customer's total order count
        ) AS total_orders
    FROM all_customer_orders
),

-- -------------------------------------------------------------
-- CTE 3: returning_customers
-- Customers who placed more than 1 order = retained customers.
-- This is the denominator for the overall retention rate.
-- -------------------------------------------------------------
returning_customers AS (
    SELECT
        customer_unique_id,
        total_orders,
        MIN(order_purchase_timestamp) AS first_purchase_date,   -- first order date
        MAX(order_purchase_timestamp) AS last_purchase_date,    -- last order date
        -- Days between first and last purchase: measures the customer's "lifecycle"
        CAST(
            (JULIANDAY(MAX(order_purchase_timestamp))
             - JULIANDAY(MIN(order_purchase_timestamp))) AS INTEGER
        ) AS days_between_first_last
    FROM order_sequence
    GROUP BY customer_unique_id
    HAVING COUNT(order_id) > 1              -- only customers with more than 1 order
),

-- -------------------------------------------------------------
-- CTE 4: first_orders_with_category
-- Identifies the category of each customer's first order.
-- Tells us "what category did the customer buy initially?"
-- We use this category to measure whether it retains customers.
-- -------------------------------------------------------------
-- FIXED (portfolio review, priority 3): the previous version joined
-- order_items without aggregating, so a first order with several
-- items produced several rows per customer; if those items belonged
-- to different categories, the customer was counted in MORE THAN
-- ONE category in category_retention_stats (fan-out). Here a single
-- "main" item per order is chosen (the highest-priced one) before
-- joining to product/category, matching the same business rule used
-- in 02_data_preparation.
main_item_per_order AS (
    SELECT order_id, product_id
    FROM (
        SELECT
            order_id,
            product_id,
            ROW_NUMBER() OVER (
                PARTITION BY order_id ORDER BY price DESC, order_item_id ASC
            ) AS rn
        FROM order_items
    )
    WHERE rn = 1
),
first_orders_with_category AS (
    SELECT
        os.customer_unique_id,
        os.order_id,
        os.order_purchase_timestamp                 AS first_purchase_date,
        os.total_orders,
        COALESCE(t.product_category_name_english, 'unknown') AS first_category_en
    FROM order_sequence os
    -- Join with the main (highest-priced) item of the first order
    INNER JOIN main_item_per_order oi
        ON os.order_id = oi.order_id
    -- Join with products to get the product's category
    LEFT JOIN products p
        ON oi.product_id = p.product_id
    -- Join with translation to get the English category
    LEFT JOIN category_translation t
        ON p.product_category_name = t.product_category_name
    WHERE os.purchase_rank = 1              -- only each customer's first order
),

-- -------------------------------------------------------------
-- CTE 5: category_retention_stats
-- For each category: counts total customers whose first purchase
-- was there, and how many of them came back to buy again.
-- Retention rate = retained / total customers in the category.
-- -------------------------------------------------------------
category_retention_stats AS (
    SELECT
        foc.first_category_en                           AS category,
        COUNT(DISTINCT foc.customer_unique_id)          AS total_customers,
        -- Retained customers: those with total_orders > 1
        COUNT(DISTINCT CASE WHEN foc.total_orders > 1
                            THEN foc.customer_unique_id END)
                                                        AS retained_customers,
        -- Retention rate as a percentage (2 decimals)
        ROUND(
            COUNT(DISTINCT CASE WHEN foc.total_orders > 1
                                THEN foc.customer_unique_id END)
            * 100.0 / NULLIF(COUNT(DISTINCT foc.customer_unique_id), 0),
            2
        )                                               AS retention_rate_pct,
        -- Average orders per retained customer
        ROUND(
            AVG(CASE WHEN foc.total_orders > 1
                     THEN CAST(foc.total_orders AS FLOAT) END),
            2
        )                                               AS avg_orders_retained_customers
    FROM first_orders_with_category foc
    GROUP BY foc.first_category_en
    HAVING COUNT(DISTINCT foc.customer_unique_id) >= 50  -- minimum 50 customers for significance
),

-- -------------------------------------------------------------
-- CTE 6: category_ranking
-- Applies window functions to rank categories by retention.
-- RANK() handles ties (two categories with the same % share the rank).
-- NTILE(4) buckets into quartiles: top 25%, second 25%, etc.
-- -------------------------------------------------------------
category_ranking AS (
    SELECT
        category,
        total_customers,
        retained_customers,
        retention_rate_pct,
        avg_orders_retained_customers,
        -- Rank by retention rate (1 = most loyalty-generating category)
        RANK() OVER (ORDER BY retention_rate_pct DESC)      AS retention_rank,
        -- Retention quartile (1=best 25%, 4=worst 25%)
        NTILE(4) OVER (ORDER BY retention_rate_pct DESC)    AS retention_quartile,
        -- Rank by customer volume (1 = most massive category)
        RANK() OVER (ORDER BY total_customers DESC)         AS volume_rank,
        -- Difference between retained and churn (to spot high-churn categories)
        (total_customers - retained_customers)              AS churned_customers
    FROM category_retention_stats
),

-- -------------------------------------------------------------
-- CTE 7: first_vs_repeat_stats
-- Compares behavior on the first purchase vs. later purchases.
-- Measures whether customers spend more or less on repeat purchases.
-- -------------------------------------------------------------
first_vs_repeat_stats AS (
    SELECT
        os.purchase_rank,
        CASE
            WHEN os.purchase_rank = 1 THEN 'First purchase'
            WHEN os.purchase_rank = 2 THEN 'Second purchase'
            ELSE 'Third purchase or more'
        END                             AS purchase_type,
        COUNT(DISTINCT os.order_id)     AS num_orders,
        -- Average order value depending on whether it's a first purchase or not
        ROUND(AVG(oi_agg.price_total), 2)   AS avg_order_value,
        ROUND(AVG(oi_agg.n_items), 2)       AS avg_items_per_order
    FROM order_sequence os
    INNER JOIN (
        -- Subquery: aggregates order_items to order level
        SELECT
            order_id,
            SUM(price)          AS price_total,
            COUNT(order_item_id) AS n_items
        FROM order_items
        GROUP BY order_id
    ) oi_agg ON os.order_id = oi_agg.order_id
    GROUP BY os.purchase_rank,
             CASE
                 WHEN os.purchase_rank = 1 THEN 'First purchase'
                 WHEN os.purchase_rank = 2 THEN 'Second purchase'
                 ELSE 'Third purchase or more'
             END
)


-- =============================================================
-- RESULT 1: ALL categories (>=50 customers) ranked by retention
-- rate.
-- FIXED (portfolio review, priority 3): this used to have
-- "LIMIT 20", so "the worst categories" cited by notebook 05
-- (nsmallest(3) over this result) were actually ranks 18-20 of the
-- BEST ones, never the categories with the real lowest retention
-- (several at 0%, outside the top 20). Without LIMIT, the notebook
-- filters or paginates as needed.
-- =============================================================
SELECT
    retention_rank,
    category,
    total_customers,
    retained_customers,
    churned_customers,
    retention_rate_pct              AS retention_pct,
    avg_orders_retained_customers   AS avg_orders_returning,
    retention_quartile,
    volume_rank
FROM category_ranking
ORDER BY retention_rank;


-- =============================================================
-- RESULT 2: First purchase vs. later purchases
-- Do loyal customers spend more on repeat purchases?
-- =============================================================
-- SELECT * FROM first_vs_repeat_stats ORDER BY purchase_rank;


-- =============================================================
-- RESULT 3: Global retention statistics
-- =============================================================
-- SELECT
--     COUNT(DISTINCT customer_unique_id)                          AS total_customers,
--     COUNT(DISTINCT CASE WHEN total_orders > 1
--                         THEN customer_unique_id END)            AS retained_customers,
--     ROUND(
--         COUNT(DISTINCT CASE WHEN total_orders > 1
--                             THEN customer_unique_id END)
--         * 100.0 / COUNT(DISTINCT customer_unique_id), 2
--     )                                                           AS global_retention_rate_pct,
--     ROUND(AVG(total_orders), 2)                                 AS avg_orders_per_customer,
--     MAX(total_orders)                                           AS max_orders_single_customer
-- FROM returning_customers;
