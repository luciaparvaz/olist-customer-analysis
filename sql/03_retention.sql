-- =============================================================
-- Fase 4 CRISP-DM — Modeling: Customer Retention Analysis
-- Proyecto: Customer Behavior Analysis — Olist Brazilian E-Commerce
-- Objetivo: Identificar clientes recurrentes, calcular tasa de
--           retención por categoría y ranking de categorías por
--           capacidad de fidelizar clientes.
-- Nota: usa customer_unique_id (ID estable entre pedidos) en lugar
--       de customer_id (cambia por pedido en el dataset Olist).
-- =============================================================


-- -------------------------------------------------------------
-- CTE 1: all_customer_orders
-- Une orders con customers para obtener el ID estable del cliente
-- (customer_unique_id) y la fecha de cada pedido.
-- Solo incluimos pedidos delivered: misma lógica que el modelo.
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
    WHERE o.order_status = 'delivered'      -- foco en pedidos completados
),

-- -------------------------------------------------------------
-- CTE 2: order_sequence
-- Asigna un número de orden cronológico a cada pedido por cliente.
-- ROW_NUMBER() nos permite identificar la primera compra (rn=1)
-- y las compras posteriores (rn>1) para cada cliente.
-- -------------------------------------------------------------
order_sequence AS (
    SELECT
        customer_unique_id,
        order_id,
        order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id          -- reinicia el contador por cliente
            ORDER BY order_purchase_timestamp ASC    -- ordena cronológicamente
        ) AS purchase_rank,
        COUNT(order_id) OVER (
            PARTITION BY customer_unique_id          -- total de pedidos del cliente
        ) AS total_orders
    FROM all_customer_orders
),

-- -------------------------------------------------------------
-- CTE 3: returning_customers
-- Clientes que realizaron más de 1 pedido = clientes retenidos.
-- Este es el denominador para calcular la tasa de retención global.
-- -------------------------------------------------------------
returning_customers AS (
    SELECT
        customer_unique_id,
        total_orders,
        MIN(order_purchase_timestamp) AS first_purchase_date,   -- fecha primer pedido
        MAX(order_purchase_timestamp) AS last_purchase_date,    -- fecha último pedido
        -- Días entre primera y última compra: mide el "ciclo de vida" del cliente
        CAST(
            (JULIANDAY(MAX(order_purchase_timestamp))
             - JULIANDAY(MIN(order_purchase_timestamp))) AS INTEGER
        ) AS days_between_first_last
    FROM order_sequence
    GROUP BY customer_unique_id
    HAVING COUNT(order_id) > 1              -- solo clientes con más de 1 pedido
),

-- -------------------------------------------------------------
-- CTE 4: first_orders_with_category
-- Identifica la categoría del primer pedido de cada cliente.
-- Nos dice "¿qué categoría adquirió el cliente inicialmente?"
-- Usamos esta categoría para medir si esa categoría retiene clientes.
-- -------------------------------------------------------------
-- CORREGIDO (revisión de portfolio, prioridad 3): la versión anterior unía
-- order_items sin agregar, así que un primer pedido con varios ítems
-- generaba varias filas por cliente; si esos ítems eran de categorías
-- distintas, el cliente quedaba contado en MÁS DE UNA categoría en
-- category_retention_stats (fan-out). Aquí se elige un único ítem
-- "principal" por pedido (el de mayor precio) antes de unir con producto/
-- categoría, igual que el criterio de negocio usado en 02_data_preparation.
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
    -- Join con el ítem principal (mayor precio) del primer pedido
    INNER JOIN main_item_per_order oi
        ON os.order_id = oi.order_id
    -- Join con products para obtener la categoría del producto
    LEFT JOIN products p
        ON oi.product_id = p.product_id
    -- Join con traducción para obtener categoría en inglés
    LEFT JOIN category_translation t
        ON p.product_category_name = t.product_category_name
    WHERE os.purchase_rank = 1              -- solo el primer pedido de cada cliente
),

-- -------------------------------------------------------------
-- CTE 5: category_retention_stats
-- Para cada categoría: cuenta clientes totales que compraron allí
-- como primera compra y cuántos de ellos volvieron a comprar.
-- Tasa de retención = retenidos / total clientes en categoría.
-- -------------------------------------------------------------
category_retention_stats AS (
    SELECT
        foc.first_category_en                           AS category,
        COUNT(DISTINCT foc.customer_unique_id)          AS total_customers,
        -- Clientes retenidos: aquellos cuyo total_orders > 1
        COUNT(DISTINCT CASE WHEN foc.total_orders > 1
                            THEN foc.customer_unique_id END)
                                                        AS retained_customers,
        -- Tasa de retención como porcentaje (2 decimales)
        ROUND(
            COUNT(DISTINCT CASE WHEN foc.total_orders > 1
                                THEN foc.customer_unique_id END)
            * 100.0 / NULLIF(COUNT(DISTINCT foc.customer_unique_id), 0),
            2
        )                                               AS retention_rate_pct,
        -- Promedio de pedidos por cliente retenido
        ROUND(
            AVG(CASE WHEN foc.total_orders > 1
                     THEN CAST(foc.total_orders AS FLOAT) END),
            2
        )                                               AS avg_orders_retained_customers
    FROM first_orders_with_category foc
    GROUP BY foc.first_category_en
    HAVING COUNT(DISTINCT foc.customer_unique_id) >= 50  -- mínimo 50 clientes para significancia
),

-- -------------------------------------------------------------
-- CTE 6: category_ranking
-- Aplica Window Functions para rankear categorías por retención.
-- RANK() gestiona empates (dos categorías con el mismo % comparten rango).
-- NTILE(4) clasifica en cuartiles: top 25%, segundo 25%, etc.
-- -------------------------------------------------------------
category_ranking AS (
    SELECT
        category,
        total_customers,
        retained_customers,
        retention_rate_pct,
        avg_orders_retained_customers,
        -- Ranking por tasa de retención (1 = categoría más fidelizadora)
        RANK() OVER (ORDER BY retention_rate_pct DESC)      AS retention_rank,
        -- Cuartil de retención (1=mejor 25%, 4=peor 25%)
        NTILE(4) OVER (ORDER BY retention_rate_pct DESC)    AS retention_quartile,
        -- Ranking por volumen de clientes (1 = categoría más masiva)
        RANK() OVER (ORDER BY total_customers DESC)         AS volume_rank,
        -- Diferencia entre retained y churn (para identificar categorías con alto abandono)
        (total_customers - retained_customers)              AS churned_customers
    FROM category_retention_stats
),

-- -------------------------------------------------------------
-- CTE 7: first_vs_repeat_stats
-- Compara el comportamiento en la primera compra vs compras posteriores.
-- Mide si los clientes gastan más o menos en compras de repetición.
-- -------------------------------------------------------------
first_vs_repeat_stats AS (
    SELECT
        os.purchase_rank,
        CASE
            WHEN os.purchase_rank = 1 THEN 'Primera compra'
            WHEN os.purchase_rank = 2 THEN 'Segunda compra'
            ELSE 'Tercera compra o más'
        END                             AS purchase_type,
        COUNT(DISTINCT os.order_id)     AS num_orders,
        -- Valor medio del pedido según si es primera compra o no
        ROUND(AVG(oi_agg.price_total), 2)   AS avg_order_value,
        ROUND(AVG(oi_agg.n_items), 2)       AS avg_items_per_order
    FROM order_sequence os
    INNER JOIN (
        -- Subconsulta: agrega order_items al nivel de pedido
        SELECT
            order_id,
            SUM(price)          AS price_total,
            COUNT(order_item_id) AS n_items
        FROM order_items
        GROUP BY order_id
    ) oi_agg ON os.order_id = oi_agg.order_id
    GROUP BY os.purchase_rank,
             CASE
                 WHEN os.purchase_rank = 1 THEN 'Primera compra'
                 WHEN os.purchase_rank = 2 THEN 'Segunda compra'
                 ELSE 'Tercera compra o más'
             END
)


-- =============================================================
-- RESULTADO 1: TODAS las categorías (>=50 clientes) rankeadas por
-- tasa de retención.
-- CORREGIDO (revisión de portfolio, prioridad 3): antes tenía
-- "LIMIT 20", así que "las peores categorías" que citaba el notebook 05
-- (nsmallest(3) sobre este resultado) eran en realidad los puestos 18-20
-- de las MEJORES, nunca las categorías con retención más baja real
-- (varias con 0%, fuera del top 20). Sin LIMIT, el notebook filtra o
-- pagina como necesite.
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
-- RESULTADO 2: Primera compra vs compras posteriores
-- ¿Los clientes fieles gastan más en compras de repetición?
-- =============================================================
-- SELECT * FROM first_vs_repeat_stats ORDER BY purchase_rank;


-- =============================================================
-- RESULTADO 3: Estadísticas globales de retención
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
