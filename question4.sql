-- ============================================================================
-- Question 4
-- ============================================================================

-- Question 4 (a)
CREATE TABLE doctors (
    doctor_id       SERIAL PRIMARY KEY,
    doctor_name     VARCHAR(120) NOT NULL,
    specialty       VARCHAR(80) NOT NULL,
    consultation_fee NUMERIC(10, 2) NOT NULL CHECK (consultation_fee > 0)
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    patient_name    VARCHAR(120) NOT NULL,
    appt_date       DATE NOT NULL,
    appt_slot       VARCHAR(20) NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED', 'COMPLETED', 'CANCELLED')),
    UNIQUE (doctor_id, appt_date, appt_slot)
);

CREATE TABLE fee_change_audit (
    audit_id        SERIAL PRIMARY KEY,
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    old_fee         NUMERIC(10, 2) NOT NULL,
    new_fee         NUMERIC(10, 2) NOT NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    expected_revenue NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (expected_revenue >= 0)
);

INSERT INTO doctors (doctor_name, specialty, consultation_fee) VALUES
    ('Dr. Chileshe Mumba', 'General Medicine', 250.00),
    ('Dr. Thandiwe Kaunda', 'Pediatrics',       300.00),
    ('Dr. Mwamba Lungu',   'Dermatology',      350.00);


-- Question 4 (b)
CREATE OR REPLACE FUNCTION fn_doctor_day_revenue(
    p_doctor_id INT,
    p_day       DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_day      DATE := COALESCE(p_day, CURRENT_DATE);
    v_fee      NUMERIC(10, 2);
    v_total    NUMERIC(12, 2);
BEGIN
    SELECT consultation_fee
    INTO v_fee
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id (%): doctor does not exist.', p_doctor_id;
    END IF;

    SELECT COALESCE(COUNT(*), 0) * v_fee
    INTO v_total
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appt_date = v_day
      AND status IN ('BOOKED', 'COMPLETED');

    RETURN COALESCE(v_total, 0.00);
END;
$$;


-- Question 4 (c)
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_doctor_id    INT,
    p_patient_name VARCHAR(120),
    p_appt_date    DATE,
    p_appt_slot    VARCHAR(20)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    IF p_patient_name IS NULL OR btrim(p_patient_name) = '' THEN
        RAISE EXCEPTION 'Patient name cannot be empty.';
    END IF;

    IF p_appt_slot IS NULL OR btrim(p_appt_slot) = '' THEN
        RAISE EXCEPTION 'Appointment slot cannot be empty.';
    END IF;

    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id (%): doctor does not exist.', p_doctor_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM appointments
        WHERE doctor_id = p_doctor_id
          AND appt_date = p_appt_date
          AND appt_slot = btrim(p_appt_slot)
          AND status IN ('BOOKED', 'COMPLETED')
    )
    INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Slot (%) on % is already taken for doctor_id (%).',
            btrim(p_appt_slot), p_appt_date, p_doctor_id;
    END IF;

    INSERT INTO appointments (doctor_id, patient_name, appt_date, appt_slot, status)
    VALUES (p_doctor_id, btrim(p_patient_name), p_appt_date, btrim(p_appt_slot), 'BOOKED');
END;
$$;


-- Question 4 (d)
CREATE OR REPLACE FUNCTION fn_trg_doctors_fee_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.consultation_fee IS DISTINCT FROM OLD.consultation_fee THEN
        INSERT INTO fee_change_audit (doctor_id, old_fee, new_fee, changed_at)
        VALUES (NEW.doctor_id, OLD.consultation_fee, NEW.consultation_fee, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_doctors_after_update_fee
AFTER UPDATE OF consultation_fee ON doctors
FOR EACH ROW
WHEN (OLD.consultation_fee IS DISTINCT FROM NEW.consultation_fee)
EXECUTE FUNCTION fn_trg_doctors_fee_audit();


-- Question 4 (a) - Appointments loaded via pr_book_appointment
CALL pr_book_appointment(1, 'Mutale Banda',  DATE '2026-11-23', '09:00-09:30');
CALL pr_book_appointment(1, 'Chanda Mwamba', DATE '2026-11-23', '09:30-10:00');
CALL pr_book_appointment(1, 'Bwalya Phiri',  DATE '2026-11-24', '10:00-10:30');
CALL pr_book_appointment(2, 'Mwape Tembo',   DATE '2026-11-23', '11:00-11:30');
CALL pr_book_appointment(2, 'Luyando Zulu',  DATE '2026-11-24', '14:00-14:30');
CALL pr_book_appointment(3, 'Kabwe Lungu',   DATE '2026-11-24', '15:00-15:30');


-- Question 4 (e)
CREATE OR REPLACE VIEW v_upcoming_appointments AS
SELECT
    a.appointment_id,
    a.appt_date,
    a.appt_slot,
    d.doctor_name,
    d.specialty,
    a.patient_name,
    a.status
FROM appointments a
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appt_date >= CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.appt_date ASC, a.appt_slot ASC, a.appointment_id ASC;

SELECT * FROM v_upcoming_appointments;


-- Question 4 (f)
-- Composite index on (doctor_id, appt_date) accelerates filtering by doctor and
-- scanning appointment dates; INCLUDE (appt_slot, patient_name, status) allows
-- index-only retrieval of schedule details.
CREATE INDEX idx_appointments_doctor_date
ON appointments (doctor_id, appt_date)
INCLUDE (appt_slot, patient_name, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    appointment_id,
    appt_date,
    appt_slot,
    patient_name,
    status
FROM appointments
WHERE doctor_id = 1
  AND appt_date BETWEEN DATE '2026-11-23' AND DATE '2026-11-25'
ORDER BY appt_date, appt_slot;


-- Question 4 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, CURRENT_DATE);
BEGIN
    INSERT INTO daily_clinic_summary (summary_date, booked_count, expected_revenue)
    SELECT
        v_target_day AS summary_date,
        COUNT(*) FILTER (WHERE a.status IN ('BOOKED', 'COMPLETED'))::INT AS booked_count,
        COALESCE(SUM(d.consultation_fee) FILTER (WHERE a.status IN ('BOOKED', 'COMPLETED')), 0.00) AS expected_revenue
    FROM appointments a
    JOIN doctors d ON d.doctor_id = a.doctor_id
    WHERE a.appt_date = v_target_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count     = EXCLUDED.booked_count,
        expected_revenue = EXCLUDED.expected_revenue;
END;
$$;

-- Daily schedule at 00:05 for CURRENT_DATE: 5 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_clinic_summary(CURRENT_DATE);"

CALL pr_refresh_clinic_summary(DATE '2026-11-24');
CALL pr_refresh_clinic_summary(DATE '2026-11-24');
SELECT * FROM daily_clinic_summary;