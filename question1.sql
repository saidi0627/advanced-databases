-- ============================================================================
-- Question 1
-- ============================================================================

-- Question 1 (a)
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id       SERIAL PRIMARY KEY,
    medicine_id   INT NOT NULL REFERENCES medicines(medicine_id),
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id      SERIAL PRIMARY KEY,
    medicine_id   INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty       INT NOT NULL,
    new_qty       INT NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date    DATE PRIMARY KEY,
    total_qty     INT NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 25.00, 14),
    ('Amoxicillin 250mg', 45.00, 30),
    ('Ibuprofen 400mg',   30.00, 25);


-- Question 1 (b)
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INT,
    p_quantity    INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity (%): quantity must be greater than zero.', p_quantity;
    END IF;

    SELECT unit_price
    INTO v_unit_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id (%): medicine does not exist.', p_medicine_id;
    END IF;

    RETURN v_unit_price * p_quantity;
END;
$$;


-- Question 1 (c)
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
    v_stock_qty  INT;
    v_sale_date  DATE := COALESCE(p_sold_on, CURRENT_DATE);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity (%): quantity must be greater than zero.', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
    INTO v_unit_price, v_stock_qty
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id (%): medicine does not exist.', p_medicine_id;
    END IF;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id (%): available %, requested %.',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, v_sale_date);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;


-- Question 1 (d)
CREATE OR REPLACE FUNCTION fn_trg_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_after_update_stock
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_trg_medicines_stock_audit();


-- Question 1 (a) - Sales loaded via pr_record_sale
CALL pr_record_sale(1, 3, DATE '2026-11-22');
CALL pr_record_sale(1, 2, DATE '2026-11-23');
CALL pr_record_sale(2, 5, DATE '2026-11-23');
CALL pr_record_sale(3, 4, DATE '2026-11-23');
CALL pr_record_sale(2, 4, DATE '2026-11-24');
CALL pr_record_sale(1, 2, DATE '2026-11-24');


-- Question 1 (e)
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty ASC, medicine_name;

SELECT * FROM v_low_stock;


-- Question 1 (f)
-- Composite index on (medicine_id, sold_on) matches equality on medicine_id
-- and range filtering on sold_on; INCLUDE (quantity, unit_price) supports
-- index-only scans for sales totals and amounts.
CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on)
INCLUDE (quantity, unit_price);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    sale_id,
    sold_on,
    quantity,
    unit_price,
    quantity * unit_price AS line_total
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY sold_on;


-- Question 1 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT
        v_target_day AS sales_date,
        COALESCE(SUM(quantity), 0)::INT AS total_qty,
        COALESCE(SUM(quantity * unit_price), 0.00) AS total_amount
    FROM sales
    WHERE sold_on = v_target_day
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Daily schedule at 00:15 for previous day: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_sales(DATE '2026-11-23');
CALL pr_refresh_sales(DATE '2026-11-23');
SELECT * FROM daily_sales;
