-- ============================================================================
-- Question 7
-- ============================================================================

-- Question 7 (a)
CREATE TABLE rooms (
    room_id       SERIAL PRIMARY KEY,
    room_number   VARCHAR(20) NOT NULL UNIQUE,
    room_type     VARCHAR(50) NOT NULL,
    nightly_rate  NUMERIC(10, 2) NOT NULL CHECK (nightly_rate > 0),
    is_available  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE bookings (
    booking_id    SERIAL PRIMARY KEY,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    guest_name    VARCHAR(120) NOT NULL,
    check_in      DATE NOT NULL,
    check_out     DATE NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED'
                  CHECK (status IN ('CONFIRMED', 'CHECKED_OUT', 'CANCELLED')),
    CHECK (check_out > check_in)
);

CREATE TABLE rate_audit (
    audit_id      SERIAL PRIMARY KEY,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    old_rate      NUMERIC(10, 2) NOT NULL,
    new_rate      NUMERIC(10, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_occupancy_summary (
    summary_date  DATE PRIMARY KEY,
    booked_rooms  INT NOT NULL DEFAULT 0 CHECK (booked_rooms >= 0),
    room_revenue  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (room_revenue >= 0)
);

INSERT INTO rooms (room_number, room_type, nightly_rate, is_available) VALUES
    ('101', 'Standard Single', 650.00, TRUE),
    ('202', 'Deluxe Double',   950.00, TRUE),
    ('303', 'Executive Suite', 1500.00, TRUE);


-- Question 7 (b)
CREATE OR REPLACE FUNCTION fn_booking_total(
    p_room_id   INT,
    p_check_in  DATE,
    p_check_out DATE
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate   NUMERIC(10, 2);
    v_nights INT;
BEGIN
    IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
        RAISE EXCEPTION 'Invalid stay dates: check_out (%) must be later than check_in (%).',
            p_check_out, p_check_in;
    END IF;

    SELECT nightly_rate
    INTO v_rate
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id (%): room does not exist.', p_room_id;
    END IF;

    v_nights := (p_check_out - p_check_in);
    RETURN (v_nights * v_rate)::NUMERIC(12, 2);
END;
$$;


-- Question 7 (c)
CREATE OR REPLACE PROCEDURE pr_create_booking(
    p_room_id    INT,
    p_guest_name VARCHAR(120),
    p_check_in   DATE,
    p_check_out  DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_overlap_exists BOOLEAN;
BEGIN
    IF p_guest_name IS NULL OR btrim(p_guest_name) = '' THEN
        RAISE EXCEPTION 'Guest name cannot be empty.';
    END IF;

    IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
        RAISE EXCEPTION 'Invalid stay dates: check_out (%) must be later than check_in (%).',
            p_check_out, p_check_in;
    END IF;

    PERFORM 1
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id (%): room does not exist.', p_room_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM bookings
        WHERE room_id = p_room_id
          AND status IN ('CONFIRMED', 'CHECKED_OUT')
          AND p_check_in < check_out
          AND p_check_out > check_in
    )
    INTO v_overlap_exists;

    IF v_overlap_exists THEN
        RAISE EXCEPTION 'Room (%) already has a booking overlapping % to %.',
            p_room_id, p_check_in, p_check_out;
    END IF;

    INSERT INTO bookings (room_id, guest_name, check_in, check_out, status)
    VALUES (p_room_id, btrim(p_guest_name), p_check_in, p_check_out, 'CONFIRMED');
END;
$$;


-- Question 7 (d)
CREATE OR REPLACE FUNCTION fn_trg_rooms_rate_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.nightly_rate IS DISTINCT FROM OLD.nightly_rate THEN
        INSERT INTO rate_audit (room_id, old_rate, new_rate, changed_at)
        VALUES (NEW.room_id, OLD.nightly_rate, NEW.nightly_rate, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_rooms_after_update_nightly_rate
AFTER UPDATE OF nightly_rate ON rooms
FOR EACH ROW
WHEN (OLD.nightly_rate IS DISTINCT FROM NEW.nightly_rate)
EXECUTE FUNCTION fn_trg_rooms_rate_audit();


-- Question 7 (a) - Bookings loaded via pr_create_booking
CALL pr_create_booking(1, 'Chanda Mwamba', DATE '2026-11-22', DATE '2026-11-24');
CALL pr_create_booking(1, 'Mutale Banda',  DATE '2026-11-24', DATE '2026-11-26');
CALL pr_create_booking(2, 'Bwalya Phiri',  DATE '2026-11-23', DATE '2026-11-25');
CALL pr_create_booking(2, 'Mwape Tembo',   DATE '2026-11-26', DATE '2026-11-28');
CALL pr_create_booking(3, 'Luyando Zulu',  DATE '2026-11-24', DATE '2026-11-27');
CALL pr_create_booking(3, 'Kabwe Lungu',   DATE '2026-11-28', DATE '2026-11-30');


-- Question 7 (e)
CREATE OR REPLACE VIEW v_active_bookings AS
SELECT
    b.booking_id,
    r.room_number,
    r.room_type,
    b.guest_name,
    b.check_in,
    b.check_out,
    fn_booking_total(b.room_id, b.check_in, b.check_out) AS total_amount,
    b.status
FROM bookings b
JOIN rooms r ON r.room_id = b.room_id
WHERE b.status = 'CONFIRMED'
  AND b.check_out >= CURRENT_DATE
ORDER BY b.check_in ASC, r.room_number ASC;

SELECT * FROM v_active_bookings;


-- Question 7 (f)
-- Composite index on (room_id, check_in, check_out) accelerates room-level
-- stay lookups and overlap/date-range checks; INCLUDE (guest_name, status)
-- avoids extra heap lookups for booking listings.
CREATE INDEX idx_bookings_room_dates
ON bookings (room_id, check_in, check_out)
INCLUDE (guest_name, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    booking_id,
    guest_name,
    check_in,
    check_out,
    status
FROM bookings
WHERE room_id = 1
  AND check_in >= DATE '2026-11-22'
  AND check_out <= DATE '2026-11-27'
ORDER BY check_in;


-- Question 7 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy_summary(
    p_day DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, CURRENT_DATE);
BEGIN
    INSERT INTO daily_occupancy_summary (summary_date, booked_rooms, room_revenue)
    SELECT
        v_target_day AS summary_date,
        COUNT(DISTINCT b.room_id)::INT AS booked_rooms,
        COALESCE(SUM(r.nightly_rate), 0.00) AS room_revenue
    FROM bookings b
    JOIN rooms r ON r.room_id = b.room_id
    WHERE b.status IN ('CONFIRMED', 'CHECKED_OUT')
      AND b.check_in <= v_target_day
      AND b.check_out > v_target_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_rooms = EXCLUDED.booked_rooms,
        room_revenue = EXCLUDED.room_revenue;
END;
$$;

-- Daily schedule at 00:15 for CURRENT_DATE: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_occupancy_summary(CURRENT_DATE);"

CALL pr_refresh_occupancy_summary(DATE '2026-11-24');
CALL pr_refresh_occupancy_summary(DATE '2026-11-24');
SELECT * FROM daily_occupancy_summary;