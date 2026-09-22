-- =============================================================
-- Fase 3 CRISP-DM — Data Preparation
-- Proyecto: Customer Behavior Analysis — Olist Brazilian E-Commerce
-- Objetivo: Construir tabla maestra a nivel order_id con variables
--           limpias y features de negocio listas para modelado.
-- =============================================================


-- -------------------------------------------------------------
-- CTE 1: delivered_orders
-- Base del análisis: solo pedidos con status 'delivered'.
-- Excluimos pedidos cancelados, en tránsito o con incidencias
-- porque no tienen fecha de entrega real para calcular el delay.
-- -------------------------------------------------------------
WITH delivered_orders AS (
    SELECT
        order_id,
        customer_id,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date,      -- fecha real de entrega al cliente
        order_estimated_delivery_date       -- fecha prometida al cliente
    FROM orders
    WHERE order_status = 'delivered'        -- foco en pedidos completados
      AND order_delivered_customer_date IS NOT NULL   -- garantizamos fecha real disponible
      AND order_estimated_delivery_date IS NOT NULL   -- garantizamos fecha prometida disponible
),

-- -------------------------------------------------------------
-- CTE 2: items_aggregated
-- order_items tiene una fila por ítem dentro del pedido.
-- Agrupamos al nivel order_id para poder hacer el join 1-a-1.
-- Calculamos el valor total, flete total y número de ítems.
-- -------------------------------------------------------------
items_aggregated AS (
    SELECT
        order_id,
        COUNT(order_item_id)        AS n_items,         -- cuántos productos distintos en el pedido
        SUM(price)                  AS price_total,     -- suma de precios sin flete
        SUM(freight_value)          AS freight_total,   -- coste logístico total
        MIN(seller_id)              AS seller_id,       -- vendedor principal (primer ítem)
        MIN(product_id)             AS product_id       -- producto principal (primer ítem)
    FROM order_items
    GROUP BY order_id
),

-- -------------------------------------------------------------
-- CTE 3: reviews_per_order
-- En teoría hay una reseña por pedido, pero puede haber duplicados
-- (99.224 filas de order_reviews sobre 98.673 order_id únicos).
-- CORREGIDO (revisión de portfolio, prioridad 5): el filtro anterior
-- ("WHERE review_id IN (SELECT MAX(review_id) ... GROUP BY order_id)")
-- tenía dos bugs: (a) review_id es un hash, MAX() es orden lexicográfico,
-- no "la más reciente"; (b) el IN no está correlacionado con order_id, así
-- que puede sobrevivir más de una fila por pedido si dos order_id distintos
-- comparten el mismo MAX(review_id) global (no ocurre aquí, pero el filtro
-- no lo garantiza). Se sustituye por ROW_NUMBER particionado por order_id,
-- ordenado por review_answer_timestamp real, con un desempate explícito por
-- review_id para determinismo.
-- Se conserva review_creation_date/review_answer_timestamp (antes se
-- descartaban en el notebook 02) para poder verificar en el notebook 03 si
-- la reseña se escribió antes o después de la entrega real del pedido
-- (posible fuga temporal en el análisis de drivers de reseña negativa).
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
        -- Flag de reseña negativa: scores 1 y 2 indican insatisfacción clara.
        -- Score 3 es neutral y se excluye del flag negativo.
        CASE WHEN review_score <= 2 THEN 1 ELSE 0 END  AS is_negative_review
    FROM reviews_deduped
    WHERE rn = 1
),

-- -------------------------------------------------------------
-- CTE 4: customer_info
-- Datos del cliente: usamos customer_unique_id para identificar
-- al cliente real a lo largo del tiempo (customer_id cambia por pedido).
-- -------------------------------------------------------------
customer_info AS (
    SELECT
        customer_id,
        customer_unique_id,     -- ID estable del cliente (para análisis RFM)
        customer_city,
        customer_state
    FROM customers
),

-- -------------------------------------------------------------
-- CTE 5: product_categories
-- Une productos con la traducción de categorías al inglés.
-- Los productos sin categoría (NULL) quedan marcados como 'unknown'.
-- -------------------------------------------------------------
product_categories AS (
    SELECT
        p.product_id,
        COALESCE(t.product_category_name_english, 'unknown') AS category_en,
        p.product_weight_g
    FROM products p
    LEFT JOIN category_translation t
        ON p.product_category_name = t.product_category_name
    -- LEFT JOIN para no perder productos sin categoría asignada
),

-- -------------------------------------------------------------
-- CTE 6: master_table
-- Join central: une todas las CTEs anteriores alrededor del pedido.
-- Calcula los features de negocio finales.
-- -------------------------------------------------------------
master_table AS (
    SELECT
        -- Identificadores
        o.order_id,
        c.customer_unique_id,
        c.customer_state,
        c.customer_city,
        pc.category_en,

        -- Temporalidad: útil para estacionalidad y tendencias
        o.order_purchase_timestamp,
        STRFTIME('%Y-%m', o.order_purchase_timestamp)   AS order_month,     -- mes de compra
        STRFTIME('%w',   o.order_purchase_timestamp)    AS order_weekday,   -- día semana (0=Dom)

        -- Métricas de entrega
        JULIANDAY(o.order_delivered_customer_date)
            - JULIANDAY(o.order_purchase_timestamp)     AS delivery_days,   -- días totales compra→entrega

        -- Feature principal: retraso real vs promesa.
        -- Positivo = entregado tarde (mala experiencia).
        -- Negativo = entregado antes de lo prometido (buena experiencia).
        JULIANDAY(o.order_delivered_customer_date)
            - JULIANDAY(o.order_estimated_delivery_date) AS delivery_delay_days,

        -- Métricas económicas
        i.n_items,
        i.price_total,
        i.freight_total,
        -- Ratio flete/precio: indica si el cliente pagó mucho en logística
        ROUND(i.freight_total * 1.0 / NULLIF(i.price_total, 0), 4) AS freight_ratio,

        -- Satisfacción del cliente
        r.review_score,
        r.is_negative_review,
        -- Conservadas (antes se descartaban) para poder verificar si la reseña
        -- se escribió antes o después de la entrega real (posible fuga temporal
        -- en el análisis de drivers de la Fase 4/notebook 03).
        r.review_creation_date,
        r.review_answer_timestamp,
        CASE WHEN r.review_creation_date IS NOT NULL
                  AND r.review_creation_date < o.order_delivered_customer_date
             THEN 1 ELSE 0 END AS review_before_delivery,

        -- Peso del producto (proxy de categoría/tamaño del paquete)
        pc.product_weight_g

    FROM delivered_orders o
    -- JOIN con ítems: todos los pedidos delivered deben tener ítems
    INNER JOIN items_aggregated i
        ON o.order_id = i.order_id
    -- JOIN con producto/categoría del ítem principal
    LEFT JOIN product_categories pc
        ON i.product_id = pc.product_id
    -- LEFT JOIN con reseñas: no todos los pedidos tienen reseña
    LEFT JOIN reviews_per_order r
        ON o.order_id = r.order_id
    -- INNER JOIN con clientes: todo pedido debe tener cliente
    INNER JOIN customer_info c
        ON o.customer_id = c.customer_id
)

-- =============================================================
-- Resultado final: tabla maestra lista para modelado.
-- Filtramos delivery_days > 0 para eliminar registros corruptos
-- (pedidos donde la entrega figura antes de la compra).
-- =============================================================
SELECT *
FROM master_table
WHERE delivery_days > 0
ORDER BY order_purchase_timestamp;
