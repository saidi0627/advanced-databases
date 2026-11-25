-- ============================================================================
-- Question 10
-- ============================================================================

-- Question 10 (a)
CREATE TABLE suppliers (
    supplier_id   SERIAL PRIMARY KEY,
    supplier_name VARCHAR(120) NOT NULL,
    contact_email VARCHAR(120) NOT NULL UNIQUE,
    credit_limit  NUMERIC(12, 2) NOT NULL CHECK (credit_limit > 0)
);

CREATE TABLE purchase_orders (
    po_id         SERIAL PRIMARY KEY,
    supplier_id   INT NOT NULL REFERENCES suppliers(supplier_id),
    po_amount     NUMERIC(12, 2) NOT NULL CHECK (po_amount > 0),
    ordered_on    DATE NOT NULL DEFAULT CURRENT_DATE,
    status        VARCHAR(20) NOT NULL DEFAULT 'OPEN'
                  CHECK (status IN ('OPEN', 'RECEIVED', 'CANCELLED'))
);

CREATE TABLE credit_audit (
    audit_id      SERIAL PRIMARY KEY,
    supplier_id   INT NOT NULL REFERENCES suppliers(supplier_id),
    old_limit     NUMERIC(12, 2) NOT NULL,
    new_limit     NUMERIC(12, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_procurement_summary (
    summary_date  DATE PRIMARY KEY,
    po_count      INT NOT NULL DEFAULT 0 CHECK (po_count >= 0),
    total_ordered NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (total_ordered >= 0)
);

INSERT INTO suppliers (supplier_name, contact_email, credit_limit) VALUES
    ('Zambia MedSupply Ltd',  'orders@zambiamed.co.zm',  50000.00),
    ('Copperbelt Lab Corp',   'sales@copperbeltlab.zm',  35000.00),
    ('Lusaka Office Mart',    'billing@lusakamart.zm',   25000.00);


-- Question 10 (b)
CREATE OR REPLACE FUNCTION fn_available_credit(
    p_supplier_id INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_limit     NUMERIC(12, 2);
    v_committed NUMERIC(12, 2);
BEGIN
    SELECT credit_limit
    INTO v_limit
    FROM suppliers
    WHERE supplier_id = p_supplier_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown supplier_id (%): supplier does not exist.', p_supplier_id;
    END IF;

    SELECT COALESCE(SUM(po_amount), 0.00)
    INTO v_committed
    FROM purchase_orders
    WHERE supplier_id = p_supplier_id
      AND status IN ('OPEN', 'RECEIVED');

    RETURN GREATEST(v_limit - v_committed, 0.00);
END;
$$;


-- Question 10 (c)
CREATE OR REPLACE PROCEDURE pr_create_purchase_order(
    p_supplier_id INT,
    p_po_amount   NUMERIC(12, 2),
    p_ordered_on  DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_limit      NUMERIC(12, 2);
    v_committed  NUMERIC(12, 2);
    v_ordered_on DATE := COALESCE(p_ordered_on, CURRENT_DATE);
BEGIN
    IF p_po_amount IS NULL OR p_po_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid PO amount (%): amount must be greater than zero.', p_po_amount;
    END IF;

    SELECT credit_limit
    INTO v_limit
    FROM suppliers
    WHERE supplier_id = p_supplier_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown supplier_id (%): supplier does not exist.', p_supplier_id;
    END IF;

    SELECT COALESCE(SUM(po_amount), 0.00)
    INTO v_committed
    FROM purchase_orders
    WHERE supplier_id = p_supplier_id
      AND status IN ('OPEN', 'RECEIVED');

    IF v_committed + p_po_amount > v_limit THEN
        RAISE EXCEPTION 'Credit limit exceeded for supplier_id (%): limit %, committed %, requested %.',
            p_supplier_id, v_limit, v_committed, p_po_amount;
    END IF;

    INSERT INTO purchase_orders (supplier_id, po_amount, ordered_on, status)
    VALUES (p_supplier_id, p_po_amount, v_ordered_on, 'OPEN');
END;
$$;


-- Question 10 (d)
CREATE OR REPLACE FUNCTION fn_trg_suppliers_credit_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.credit_limit IS DISTINCT FROM OLD.credit_limit THEN
        INSERT INTO credit_audit (supplier_id, old_limit, new_limit, changed_at)
        VALUES (NEW.supplier_id, OLD.credit_limit, NEW.credit_limit, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_suppliers_after_update_credit_limit
AFTER UPDATE OF credit_limit ON suppliers
FOR EACH ROW
WHEN (OLD.credit_limit IS DISTINCT FROM NEW.credit_limit)
EXECUTE FUNCTION fn_trg_suppliers_credit_audit();


-- Question 10 (a) - Purchase orders loaded via pr_create_purchase_order
CALL pr_create_purchase_order(1, 12000.00, DATE '2026-11-22');
CALL pr_create_purchase_order(1,  8500.00, DATE '2026-11-23');
CALL pr_create_purchase_order(2, 10000.00, DATE '2026-11-23');
CALL pr_create_purchase_order(2,  6500.00, DATE '2026-11-24');
CALL pr_create_purchase_order(3,  7000.00, DATE '2026-11-23');
CALL pr_create_purchase_order(3,  4500.00, DATE '2026-11-24');


-- Question 10 (e)
CREATE OR REPLACE VIEW v_open_purchase_orders AS
SELECT
    po.po_id,
    s.supplier_name,
    s.contact_email,
    po.ordered_on,
    po.po_amount,
    po.status
FROM purchase_orders po
JOIN suppliers s ON s.supplier_id = po.supplier_id
WHERE po.status = 'OPEN'
ORDER BY po.ordered_on ASC, po.po_id ASC;

SELECT * FROM v_open_purchase_orders;


-- Question 10 (f)
-- Composite index on (supplier_id, ordered_on) supports equality lookup by
-- supplier and range filtering on ordered_on; INCLUDE (po_amount, status)
-- enables index-only scans for procurement totals and statuses.
CREATE INDEX idx_purchase_orders_supplier_ordered_on
ON purchase_orders (supplier_id, ordered_on)
INCLUDE (po_amount, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    po_id,
    ordered_on,
    po_amount,
    status
FROM purchase_orders
WHERE supplier_id = 1
  AND ordered_on BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY ordered_on;


-- Question 10 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_procurement_summary(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_procurement_summary (summary_date, po_count, total_ordered)
    SELECT
        v_target_day AS summary_date,
        COUNT(*)::INT AS po_count,
        COALESCE(SUM(po_amount), 0.00) AS total_ordered
    FROM purchase_orders
    WHERE ordered_on = v_target_day
      AND status IN ('OPEN', 'RECEIVED')
    ON CONFLICT (summary_date)
    DO UPDATE SET
        po_count      = EXCLUDED.po_count,
        total_ordered = EXCLUDED.total_ordered;
END;
$$;

-- Daily schedule at 00:15 for previous day: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_procurement_summary((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_procurement_summary(DATE '2026-11-23');
CALL pr_refresh_procurement_summary(DATE '2026-11-23');
SELECT * FROM daily_procurement_summary;