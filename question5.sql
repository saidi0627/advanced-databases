-- ============================================================================
-- Question 5
-- ============================================================================

-- Question 5 (a)
CREATE TABLE warehouses (
    warehouse_id   SERIAL PRIMARY KEY,
    warehouse_name VARCHAR(100) NOT NULL,
    location       VARCHAR(100) NOT NULL,
    capacity_units INT NOT NULL CHECK (capacity_units > 0)
);

CREATE TABLE shipments (
    shipment_id    SERIAL PRIMARY KEY,
    warehouse_id   INT NOT NULL REFERENCES warehouses(warehouse_id),
    item_code      VARCHAR(50) NOT NULL,
    units          INT NOT NULL CHECK (units > 0),
    shipped_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE capacity_audit (
    audit_id       SERIAL PRIMARY KEY,
    warehouse_id   INT NOT NULL REFERENCES warehouses(warehouse_id),
    old_capacity   INT NOT NULL,
    new_capacity   INT NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_shipments (
    ship_date      DATE PRIMARY KEY,
    shipment_count INT NOT NULL DEFAULT 0 CHECK (shipment_count >= 0),
    total_units    INT NOT NULL DEFAULT 0 CHECK (total_units >= 0)
);

INSERT INTO warehouses (warehouse_name, location, capacity_units) VALUES
    ('Lusaka Central Hub',  'Lusaka',    500),
    ('Kitwe Northern Depot','Kitwe',     350),
    ('Ndola Copperbelt Bay','Ndola',     400);


-- Question 5 (b)
CREATE OR REPLACE FUNCTION fn_remaining_capacity(
    p_warehouse_id INT,
    p_as_of        DATE DEFAULT CURRENT_DATE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_shipped  INT;
    v_as_of    DATE := COALESCE(p_as_of, CURRENT_DATE);
BEGIN
    SELECT capacity_units
    INTO v_capacity
    FROM warehouses
    WHERE warehouse_id = p_warehouse_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown warehouse_id (%): warehouse does not exist.', p_warehouse_id;
    END IF;

    SELECT COALESCE(SUM(units), 0)::INT
    INTO v_shipped
    FROM shipments
    WHERE warehouse_id = p_warehouse_id
      AND shipped_on <= v_as_of;

    RETURN v_capacity - v_shipped;
END;
$$;


-- Question 5 (c)
CREATE OR REPLACE PROCEDURE pr_record_shipment(
    p_warehouse_id INT,
    p_item_code    VARCHAR(50),
    p_units        INT,
    p_shipped_on   DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity  INT;
    v_current_used INT;
    v_shipped_on DATE := COALESCE(p_shipped_on, CURRENT_DATE);
BEGIN
    IF p_item_code IS NULL OR btrim(p_item_code) = '' THEN
        RAISE EXCEPTION 'Item code cannot be empty.';
    END IF;

    IF p_units IS NULL OR p_units <= 0 THEN
        RAISE EXCEPTION 'Invalid units (%): units must be greater than zero.', p_units;
    END IF;

    SELECT capacity_units
    INTO v_capacity
    FROM warehouses
    WHERE warehouse_id = p_warehouse_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown warehouse_id (%): warehouse does not exist.', p_warehouse_id;
    END IF;

    SELECT COALESCE(SUM(units), 0)::INT
    INTO v_current_used
    FROM shipments
    WHERE warehouse_id = p_warehouse_id;

    IF v_current_used + p_units > v_capacity THEN
        RAISE EXCEPTION 'Capacity exceeded for warehouse_id (%): capacity %, used %, requested %.',
            p_warehouse_id, v_capacity, v_current_used, p_units;
    END IF;

    INSERT INTO shipments (warehouse_id, item_code, units, shipped_on)
    VALUES (p_warehouse_id, btrim(p_item_code), p_units, v_shipped_on);
END;
$$;


-- Question 5 (d)
CREATE OR REPLACE FUNCTION fn_trg_warehouses_capacity_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.capacity_units IS DISTINCT FROM OLD.capacity_units THEN
        INSERT INTO capacity_audit (warehouse_id, old_capacity, new_capacity, changed_at)
        VALUES (NEW.warehouse_id, OLD.capacity_units, NEW.capacity_units, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_warehouses_after_update_capacity
AFTER UPDATE OF capacity_units ON warehouses
FOR EACH ROW
WHEN (OLD.capacity_units IS DISTINCT FROM NEW.capacity_units)
EXECUTE FUNCTION fn_trg_warehouses_capacity_audit();


-- Question 5 (a) - Shipments loaded via pr_record_shipment
CALL pr_record_shipment(1, 'ITM-101', 120, DATE '2026-11-22');
CALL pr_record_shipment(1, 'ITM-102',  80, DATE '2026-11-23');
CALL pr_record_shipment(2, 'ITM-201',  90, DATE '2026-11-23');
CALL pr_record_shipment(2, 'ITM-202',  60, DATE '2026-11-24');
CALL pr_record_shipment(3, 'ITM-301', 110, DATE '2026-11-23');
CALL pr_record_shipment(3, 'ITM-302',  75, DATE '2026-11-24');


-- Question 5 (e)
CREATE OR REPLACE VIEW v_warehouse_utilization AS
SELECT
    w.warehouse_id,
    w.warehouse_name,
    w.location,
    w.capacity_units,
    COALESCE(SUM(s.units), 0)::INT AS shipped_units,
    (w.capacity_units - COALESCE(SUM(s.units), 0))::INT AS remaining_units
FROM warehouses w
LEFT JOIN shipments s ON s.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.warehouse_name, w.location, w.capacity_units
ORDER BY remaining_units ASC, w.warehouse_name;

SELECT * FROM v_warehouse_utilization;


-- Question 5 (f)
-- Composite index on (warehouse_id, shipped_on) matches equality lookup by
-- warehouse and range filtering on shipped_on; INCLUDE (item_code, units)
-- supports index-only queries for shipment summaries.
CREATE INDEX idx_shipments_warehouse_shipped_on
ON shipments (warehouse_id, shipped_on)
INCLUDE (item_code, units);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    shipment_id,
    item_code,
    units,
    shipped_on
FROM shipments
WHERE warehouse_id = 1
  AND shipped_on BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY shipped_on;


-- Question 5 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_shipments(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_shipments (ship_date, shipment_count, total_units)
    SELECT
        v_target_day AS ship_date,
        COUNT(*)::INT AS shipment_count,
        COALESCE(SUM(units), 0)::INT AS total_units
    FROM shipments
    WHERE shipped_on = v_target_day
    ON CONFLICT (ship_date)
    DO UPDATE SET
        shipment_count = EXCLUDED.shipment_count,
        total_units    = EXCLUDED.total_units;
END;
$$;

-- Daily schedule at 00:15 for previous day: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_shipments((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_shipments(DATE '2026-11-23');
CALL pr_refresh_shipments(DATE '2026-11-23');
SELECT * FROM daily_shipments;