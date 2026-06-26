-- ============================================================
-- Retail Supply Chain Inventory and Demand Intelligence
-- DataCo Smart Supply Chain dataset, PostgreSQL
-- ============================================================
-- Sections:
--   1. Star schema (dim_product, fact_orders, fact_order_items)
--   2. Staging and load (raw wide CSV -> normalized tables)
--   3. Analytical queries (the six built in Phase 2)
--   4. Schema verification join
--
-- Note: section 2 references the raw CSV header names. If your copy of
-- the dataset spells a header differently, adjust the quoted names.
-- Sections 1, 3, and 4 run as is against the star schema.
-- ============================================================


-- ------------------------------------------------------------
-- 1. STAR SCHEMA
-- ------------------------------------------------------------
-- One wide CSV is split by grain: products (what), orders (when, where,
-- how shipped), and line items (how much). Splitting stops a product's
-- price repeating across thousands of rows and keeps orders and items
-- from being conflated (one order has many items).

DROP TABLE IF EXISTS fact_order_items CASCADE;
DROP TABLE IF EXISTS fact_orders CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;

-- One row per product
CREATE TABLE dim_product (
    product_id      INTEGER PRIMARY KEY,
    product_name    TEXT    NOT NULL,
    category_name   TEXT    NOT NULL,
    department_name TEXT    NOT NULL,
    product_price   NUMERIC(10,2) NOT NULL
);

-- One row per order
CREATE TABLE fact_orders (
    order_id            INTEGER PRIMARY KEY,
    order_date          DATE     NOT NULL,
    order_region        TEXT     NOT NULL,
    market              TEXT     NOT NULL,
    shipping_mode       TEXT     NOT NULL,
    days_shipping_real  INTEGER  NOT NULL,
    days_shipping_sched INTEGER  NOT NULL,
    delivery_status     TEXT     NOT NULL,
    late_delivery_risk  SMALLINT NOT NULL          -- 1 = late, 0 = on time
);

-- One row per line item
CREATE TABLE fact_order_items (
    order_item_id   INTEGER PRIMARY KEY,
    order_id        INTEGER NOT NULL REFERENCES fact_orders(order_id),
    product_id      INTEGER NOT NULL REFERENCES dim_product(product_id),
    quantity        INTEGER NOT NULL,
    discount        NUMERIC(10,2) NOT NULL,
    sales           NUMERIC(12,2) NOT NULL,
    profit          NUMERIC(12,2) NOT NULL
);

-- Indexes the analytical queries lean on
CREATE INDEX idx_orders_date   ON fact_orders(order_date);
CREATE INDEX idx_orders_region ON fact_orders(order_region);
CREATE INDEX idx_items_order   ON fact_order_items(order_id);
CREATE INDEX idx_items_product ON fact_order_items(product_id);


-- ------------------------------------------------------------
-- 2. STAGING AND LOAD
-- ------------------------------------------------------------
-- Import the raw CSV into a staging table (every column TEXT) using
-- pgAdmin Import/Export with Encoding = LATIN1 (the DataCo file is not
-- UTF-8). Then the INSERT ... SELECTs below cast types and split the
-- wide table into the three normalized tables.
--
-- This staging table lists only the columns the loads consume. If you
-- import the full file, the other CSV columns can sit in staging unused.

DROP TABLE IF EXISTS staging;
CREATE TABLE staging (
    "Product Card Id"                  TEXT,
    "Product Name"                     TEXT,
    "Category Name"                    TEXT,
    "Department Name"                  TEXT,
    "Product Price"                    TEXT,
    "Order Id"                         TEXT,
    "order date (DateOrders)"          TEXT,
    "Order Region"                     TEXT,
    "Market"                           TEXT,
    "Shipping Mode"                    TEXT,
    "Days for shipping (real)"         TEXT,
    "Days for shipment (scheduled)"    TEXT,
    "Delivery Status"                  TEXT,
    "Late_delivery_risk"               TEXT,
    "Order Item Id"                    TEXT,
    "Order Item Quantity"              TEXT,
    "Order Item Discount"              TEXT,
    "Sales"                            TEXT,
    "Order Profit Per Order"           TEXT
);

-- (import the CSV into staging here, LATIN1 encoding)

-- Products: one row per product. DISTINCT ON guards against a product id
-- appearing twice with slightly different attribute text.
INSERT INTO dim_product (product_id, product_name, category_name, department_name, product_price)
SELECT DISTINCT ON ("Product Card Id")
    "Product Card Id"::INTEGER,
    "Product Name",
    "Category Name",
    "Department Name",
    "Product Price"::NUMERIC
FROM staging
ORDER BY "Product Card Id";

-- Orders: one row per order. The date carries a time component, so
-- to_date with an explicit MM/DD/YYYY format parses the date portion.
INSERT INTO fact_orders (order_id, order_date, order_region, market, shipping_mode,
                         days_shipping_real, days_shipping_sched, delivery_status, late_delivery_risk)
SELECT DISTINCT ON ("Order Id")
    "Order Id"::INTEGER,
    to_date("order date (DateOrders)", 'MM/DD/YYYY'),
    "Order Region",
    "Market",
    "Shipping Mode",
    "Days for shipping (real)"::INTEGER,
    "Days for shipment (scheduled)"::INTEGER,
    "Delivery Status",
    "Late_delivery_risk"::SMALLINT
FROM staging
ORDER BY "Order Id";

-- Line items: one row per item. Foreign keys hold only if the two parent
-- loads above completed, which is itself a proof the load was clean.
INSERT INTO fact_order_items (order_item_id, order_id, product_id, quantity, discount, sales, profit)
SELECT
    "Order Item Id"::INTEGER,
    "Order Id"::INTEGER,
    "Product Card Id"::INTEGER,
    "Order Item Quantity"::INTEGER,
    "Order Item Discount"::NUMERIC,
    "Sales"::NUMERIC,
    "Order Profit Per Order"::NUMERIC
FROM staging;


-- ------------------------------------------------------------
-- 3. ANALYTICAL QUERIES
-- ------------------------------------------------------------

-- 3.1 Monthly demand by SKU
-- Units sold per product per month, the base series for forecasting.
SELECT
    p.product_name,
    date_trunc('month', o.order_date) AS month,
    SUM(i.quantity)                   AS units
FROM fact_order_items i
JOIN fact_orders o ON o.order_id  = i.order_id
JOIN dim_product p ON p.product_id = i.product_id
GROUP BY p.product_name, date_trunc('month', o.order_date)
ORDER BY p.product_name, month;


-- 3.2 Late delivery rate by shipping mode and region
-- Lateness is a property of an order, not a line item, so this runs on
-- fact_orders directly. Joining to items would fan out and overcount.
SELECT
    shipping_mode,
    order_region,
    COUNT(*)                                            AS orders,
    SUM(late_delivery_risk)                             AS late_orders,
    ROUND(100.0 * SUM(late_delivery_risk) / COUNT(*), 1) AS late_pct
FROM fact_orders
GROUP BY shipping_mode, order_region
ORDER BY late_pct DESC;

-- Same metric by shipping mode only. This is where First Class stands out
-- with a very high late rate, pointing at the mode rather than geography.
SELECT
    shipping_mode,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * SUM(late_delivery_risk) / COUNT(*), 1) AS late_pct
FROM fact_orders
GROUP BY shipping_mode
ORDER BY late_pct DESC;


-- 3.3 Slip analysis
-- Compares actual shipping days against the scheduled promise. A positive,
-- consistent slip means lateness is a scheduling-policy problem (the
-- promise is too aggressive), not random execution failure.
SELECT
    shipping_mode,
    ROUND(AVG(days_shipping_real), 2)                       AS avg_real_days,
    ROUND(AVG(days_shipping_sched), 2)                      AS avg_sched_days,
    ROUND(AVG(days_shipping_real - days_shipping_sched), 2) AS avg_slip_days
FROM fact_orders
GROUP BY shipping_mode
ORDER BY avg_slip_days DESC;


-- 3.4 ABC classification
-- Rank products by revenue, take the running cumulative share with a
-- window function, and bucket into A (top 80%), B (next 15%), C (rest).
-- This is where a small set of SKUs is shown to drive most of revenue.
WITH product_revenue AS (
    SELECT
        p.product_id,
        p.product_name,
        SUM(i.sales) AS revenue
    FROM fact_order_items i
    JOIN dim_product p ON p.product_id = i.product_id
    GROUP BY p.product_id, p.product_name
),
ranked AS (
    SELECT
        product_name,
        revenue,
        SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () AS cumulative_share
    FROM product_revenue
)
SELECT
    product_name,
    revenue,
    ROUND(100.0 * cumulative_share, 1) AS cumulative_pct,
    CASE
        WHEN cumulative_share <= 0.80 THEN 'A'
        WHEN cumulative_share <= 0.95 THEN 'B'
        ELSE 'C'
    END AS abc_class
FROM ranked
ORDER BY revenue DESC;


-- 3.5 Lead-time variability per product
-- Lead time lives on the order (days_shipping_real); join through items to
-- attribute it to products. STDDEV measures how unpredictable each SKU's
-- delivery time is, which drives safety stock later.
SELECT
    p.product_name,
    COUNT(*)                               AS shipments,
    ROUND(AVG(o.days_shipping_real), 2)    AS avg_lead_time,
    ROUND(STDDEV(o.days_shipping_real), 2) AS lead_time_stddev
FROM fact_order_items i
JOIN fact_orders o ON o.order_id  = i.order_id
JOIN dim_product p ON p.product_id = i.product_id
GROUP BY p.product_name
HAVING COUNT(*) >= 30
ORDER BY lead_time_stddev DESC;


-- 3.6 Month-over-month demand growth
-- LAG over a window partitioned by product compares each month's units to
-- the previous month for the same product. NULLIF guards divide-by-zero.
WITH monthly AS (
    SELECT
        p.product_name,
        date_trunc('month', o.order_date) AS month,
        SUM(i.quantity)                   AS units
    FROM fact_order_items i
    JOIN fact_orders o ON o.order_id  = i.order_id
    JOIN dim_product p ON p.product_id = i.product_id
    GROUP BY p.product_name, date_trunc('month', o.order_date)
),
with_prev AS (
    SELECT
        product_name,
        month,
        units,
        LAG(units) OVER (PARTITION BY product_name ORDER BY month) AS prev_units
    FROM monthly
)
SELECT
    product_name,
    month,
    units,
    prev_units,
    ROUND(100.0 * (units - prev_units) / NULLIF(prev_units, 0), 1) AS mom_growth_pct
FROM with_prev
ORDER BY product_name, month;


-- ------------------------------------------------------------
-- 4. SCHEMA VERIFICATION JOIN
-- ------------------------------------------------------------
-- Top 10 products by revenue across all three tables. If this returns
-- sensible products and revenue, every key lines up and the star works.
SELECT
    p.product_name,
    COUNT(*)     AS line_items,
    SUM(i.sales) AS total_sales
FROM fact_order_items i
JOIN dim_product p ON p.product_id = i.product_id
JOIN fact_orders o ON o.order_id  = i.order_id
GROUP BY p.product_name
ORDER BY total_sales DESC
LIMIT 10;
