-- ============================================================================
-- Question 9
-- ============================================================================

-- Question 9 (a)
CREATE TABLE drivers (
    driver_id     SERIAL PRIMARY KEY,
    driver_name   VARCHAR(120) NOT NULL,
    vehicle_plate VARCHAR(30) NOT NULL UNIQUE,
    base_fare     NUMERIC(10, 2) NOT NULL CHECK (base_fare > 0),
    per_km_rate   NUMERIC(10, 2) NOT NULL CHECK (per_km_rate > 0)
);

CREATE TABLE trips (
    trip_id       SERIAL PRIMARY KEY,
    driver_id     INT NOT NULL REFERENCES drivers(driver_id),
    distance_km   NUMERIC(8, 2) NOT NULL CHECK (distance_km > 0),
    fare_amount   NUMERIC(10, 2) NOT NULL CHECK (fare_amount > 0),
    trip_date     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE rate_change_log (
    log_id        SERIAL PRIMARY KEY,
    driver_id     INT NOT NULL REFERENCES drivers(driver_id),
    old_per_km    NUMERIC(10, 2) NOT NULL,
    new_per_km    NUMERIC(10, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_trip_summary (
    summary_date  DATE PRIMARY KEY,
    trip_count    INT NOT NULL DEFAULT 0 CHECK (trip_count >= 0),
    total_km      NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (total_km >= 0),
    total_fares   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fares >= 0)
);

INSERT INTO drivers (driver_name, vehicle_plate, base_fare, per_km_rate) VALUES
    ('Chanda Mwamba', 'ABZ 1024', 25.00, 8.50),
    ('Mutale Banda',  'BCZ 4091', 30.00, 9.00),
    ('Bwalya Phiri',  'CDZ 7782', 20.00, 7.50);


-- Question 9 (b)
CREATE OR REPLACE FUNCTION fn_estimate_fare(
    p_driver_id   INT,
    p_distance_km NUMERIC(8, 2)
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_base_fare   NUMERIC(10, 2);
    v_per_km_rate NUMERIC(10, 2);
BEGIN
    IF p_distance_km IS NULL OR p_distance_km <= 0 THEN
        RAISE EXCEPTION 'Invalid distance (%): distance_km must be greater than zero.', p_distance_km;
    END IF;

    SELECT base_fare, per_km_rate
    INTO v_base_fare, v_per_km_rate
    FROM drivers
    WHERE driver_id = p_driver_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown driver_id (%): driver does not exist.', p_driver_id;
    END IF;

    RETURN (v_base_fare + (p_distance_km * v_per_km_rate))::NUMERIC(10, 2);
END;
$$;


-- Question 9 (c)
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_driver_id   INT,
    p_distance_km NUMERIC(8, 2),
    p_trip_date   DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fare      NUMERIC(10, 2);
    v_trip_date DATE := COALESCE(p_trip_date, CURRENT_DATE);
BEGIN
    IF p_distance_km IS NULL OR p_distance_km <= 0 THEN
        RAISE EXCEPTION 'Invalid distance (%): distance_km must be greater than zero.', p_distance_km;
    END IF;

    PERFORM 1
    FROM drivers
    WHERE driver_id = p_driver_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown driver_id (%): driver does not exist.', p_driver_id;
    END IF;

    v_fare := fn_estimate_fare(p_driver_id, p_distance_km);

    INSERT INTO trips (driver_id, distance_km, fare_amount, trip_date)
    VALUES (p_driver_id, p_distance_km, v_fare, v_trip_date);
END;
$$;


-- Question 9 (d)
CREATE OR REPLACE FUNCTION fn_trg_drivers_rate_log()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.per_km_rate IS DISTINCT FROM OLD.per_km_rate THEN
        INSERT INTO rate_change_log (driver_id, old_per_km, new_per_km, changed_at)
        VALUES (NEW.driver_id, OLD.per_km_rate, NEW.per_km_rate, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_drivers_after_update_per_km
AFTER UPDATE OF per_km_rate ON drivers
FOR EACH ROW
WHEN (OLD.per_km_rate IS DISTINCT FROM NEW.per_km_rate)
EXECUTE FUNCTION fn_trg_drivers_rate_log();


-- Question 9 (a) - Trips loaded via pr_record_trip
CALL pr_record_trip(1, 12.50, DATE '2026-11-22');
CALL pr_record_trip(1,  8.00, DATE '2026-11-23');
CALL pr_record_trip(2, 15.00, DATE '2026-11-23');
CALL pr_record_trip(2,  6.50, DATE '2026-11-24');
CALL pr_record_trip(3, 20.00, DATE '2026-11-23');
CALL pr_record_trip(3, 10.00, DATE '2026-11-24');


-- Question 9 (e)
CREATE OR REPLACE VIEW v_driver_earnings AS
SELECT
    d.driver_id,
    d.driver_name,
    d.vehicle_plate,
    COUNT(t.trip_id)::INT AS total_trips,
    COALESCE(SUM(t.distance_km), 0.00) AS total_km,
    COALESCE(SUM(t.fare_amount), 0.00) AS total_earnings
FROM drivers d
LEFT JOIN trips t ON t.driver_id = d.driver_id
GROUP BY d.driver_id, d.driver_name, d.vehicle_plate
ORDER BY total_earnings DESC, d.driver_name;

SELECT * FROM v_driver_earnings;


-- Question 9 (f)
-- Composite index on (driver_id, trip_date) accelerates equality filtering by
-- driver and range scans over trip_date; INCLUDE (distance_km, fare_amount)
-- supports index-only queries for trip totals.
CREATE INDEX idx_trips_driver_trip_date
ON trips (driver_id, trip_date)
INCLUDE (distance_km, fare_amount);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    trip_id,
    trip_date,
    distance_km,
    fare_amount
FROM trips
WHERE driver_id = 1
  AND trip_date BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY trip_date;


-- Question 9 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_trip_summary(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_trip_summary (summary_date, trip_count, total_km, total_fares)
    SELECT
        v_target_day AS summary_date,
        COUNT(*)::INT AS trip_count,
        COALESCE(SUM(distance_km), 0.00) AS total_km,
        COALESCE(SUM(fare_amount), 0.00) AS total_fares
    FROM trips
    WHERE trip_date = v_target_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        trip_count  = EXCLUDED.trip_count,
        total_km    = EXCLUDED.total_km,
        total_fares = EXCLUDED.total_fares;
END;
$$;

-- Daily schedule at 00:15 for previous day: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_trip_summary((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_trip_summary(DATE '2026-11-23');
CALL pr_refresh_trip_summary(DATE '2026-11-23');
SELECT * FROM daily_trip_summary;