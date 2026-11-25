-- ============================================================================
-- Question 2
-- ============================================================================

-- Question 2 (a)
CREATE TABLE students (
    student_id   SERIAL PRIMARY KEY,
    student_name VARCHAR(100) NOT NULL,
    fee_due      NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id   SERIAL PRIMARY KEY,
    student_id   INT NOT NULL REFERENCES students(student_id),
    amount       NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    paid_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE fee_audit (
    audit_id     SERIAL PRIMARY KEY,
    student_id   INT NOT NULL REFERENCES students(student_id),
    old_due      NUMERIC(10, 2) NOT NULL,
    new_due      NUMERIC(10, 2) NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_fees (
    fee_date     DATE PRIMARY KEY,
    total_paid   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_paid >= 0),
    tx_count     INT NOT NULL DEFAULT 0 CHECK (tx_count >= 0)
);

INSERT INTO students (student_name, fee_due) VALUES
    ('Chanda Mwamba',  2500.00),
    ('Mutale Banda',   4200.00),
    ('Bwalya Phiri',   1800.00);


-- Question 2 (b)
CREATE OR REPLACE FUNCTION fn_remaining_balance(
    p_student_id INT,
    p_payment    NUMERIC(10, 2)
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(10, 2);
BEGIN
    IF p_payment IS NULL OR p_payment <= 0 THEN
        RAISE EXCEPTION 'Invalid payment (%): payment must be greater than zero.', p_payment;
    END IF;

    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id (%): student does not exist.', p_student_id;
    END IF;

    IF p_payment > v_fee_due THEN
        RAISE EXCEPTION 'Overpayment rejected for student_id (%): payment % exceeds fee_due %.',
            p_student_id, p_payment, v_fee_due;
    END IF;

    RETURN v_fee_due - p_payment;
END;
$$;


-- Question 2 (c)
CREATE OR REPLACE PROCEDURE pr_record_payment(
    p_student_id INT,
    p_amount     NUMERIC(10, 2),
    p_paid_on    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due  NUMERIC(10, 2);
    v_paid_on  DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount (%): payment must be greater than zero.', p_amount;
    END IF;

    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id (%): student does not exist.', p_student_id;
    END IF;

    IF p_amount > v_fee_due THEN
        RAISE EXCEPTION 'Overpayment rejected for student_id (%): amount % exceeds fee_due %.',
            p_student_id, p_amount, v_fee_due;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, v_paid_on);

    UPDATE students
    SET fee_due = fee_due - p_amount
    WHERE student_id = p_student_id;
END;
$$;


-- Question 2 (d)
CREATE OR REPLACE FUNCTION fn_trg_students_fee_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.fee_due IS DISTINCT FROM OLD.fee_due THEN
        INSERT INTO fee_audit (student_id, old_due, new_due, changed_at)
        VALUES (NEW.student_id, OLD.fee_due, NEW.fee_due, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_students_after_update_fee_due
AFTER UPDATE OF fee_due ON students
FOR EACH ROW
WHEN (OLD.fee_due IS DISTINCT FROM NEW.fee_due)
EXECUTE FUNCTION fn_trg_students_fee_audit();


-- Question 2 (a) - Payments loaded via pr_record_payment
CALL pr_record_payment(1, 1000.00, DATE '2026-11-22');
CALL pr_record_payment(1,  500.00, DATE '2026-11-23');
CALL pr_record_payment(2, 1200.00, DATE '2026-11-23');
CALL pr_record_payment(3,  800.00, DATE '2026-11-23');
CALL pr_record_payment(2, 1000.00, DATE '2026-11-24');
CALL pr_record_payment(3, 1000.00, DATE '2026-11-24');


-- Question 2 (e)
CREATE OR REPLACE VIEW v_unpaid_students AS
SELECT
    student_id,
    student_name,
    fee_due
FROM students
WHERE fee_due > 0
ORDER BY fee_due DESC, student_name;

SELECT * FROM v_unpaid_students;


-- Question 2 (f)
-- Composite index on (student_id, paid_on) supports equality lookup by student
-- and range scans over paid_on; INCLUDE (amount) enables index-only scans for
-- payment totals.
CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on)
INCLUDE (amount);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    payment_id,
    paid_on,
    amount
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY paid_on;


-- Question 2 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_fees(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_fees (fee_date, total_paid, tx_count)
    SELECT
        v_target_day AS fee_date,
        COALESCE(SUM(amount), 0.00) AS total_paid,
        COUNT(*)::INT AS tx_count
    FROM payments
    WHERE paid_on = v_target_day
    ON CONFLICT (fee_date)
    DO UPDATE SET
        total_paid = EXCLUDED.total_paid,
        tx_count   = EXCLUDED.tx_count;
END;
$$;

-- Daily schedule at 00:20 for previous day: 20 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_fees((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_fees(DATE '2026-11-23');
CALL pr_refresh_fees(DATE '2026-11-23');
SELECT * FROM daily_fees;