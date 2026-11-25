-- ============================================================================
-- Question 8
-- ============================================================================

-- Question 8 (a)
CREATE TABLE courses (
    course_id     SERIAL PRIMARY KEY,
    course_code   VARCHAR(20) NOT NULL UNIQUE,
    course_title  VARCHAR(120) NOT NULL,
    credit_fee    NUMERIC(10, 2) NOT NULL CHECK (credit_fee > 0),
    max_seats     INT NOT NULL CHECK (max_seats > 0)
);

CREATE TABLE enrollments (
    enrollment_id SERIAL PRIMARY KEY,
    course_id     INT NOT NULL REFERENCES courses(course_id),
    student_name  VARCHAR(120) NOT NULL,
    enrolled_on   DATE NOT NULL DEFAULT CURRENT_DATE,
    status        VARCHAR(20) NOT NULL DEFAULT 'ENROLLED'
                  CHECK (status IN ('ENROLLED', 'DROPPED', 'COMPLETED')),
    UNIQUE (course_id, student_name)
);

CREATE TABLE fee_rate_audit (
    audit_id      SERIAL PRIMARY KEY,
    course_id     INT NOT NULL REFERENCES courses(course_id),
    old_fee       NUMERIC(10, 2) NOT NULL,
    new_fee       NUMERIC(10, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_enrollment_summary (
    summary_date  DATE PRIMARY KEY,
    active_count  INT NOT NULL DEFAULT 0 CHECK (active_count >= 0),
    projected_rev NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (projected_rev >= 0)
);

INSERT INTO courses (course_code, course_title, credit_fee, max_seats) VALUES
    ('ICT371', 'Advanced Database Systems', 1200.00, 40),
    ('ICT361', 'Mobile Application Development', 1100.00, 35),
    ('CS310',  'Theory of Computation', 1000.00, 30);


-- Question 8 (b)
CREATE OR REPLACE FUNCTION fn_course_revenue(
    p_course_id INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee   NUMERIC(10, 2);
    v_count INT;
BEGIN
    SELECT credit_fee
    INTO v_fee
    FROM courses
    WHERE course_id = p_course_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown course_id (%): course does not exist.', p_course_id;
    END IF;

    SELECT COUNT(*)::INT
    INTO v_count
    FROM enrollments
    WHERE course_id = p_course_id
      AND status IN ('ENROLLED', 'COMPLETED');

    RETURN (v_count * v_fee)::NUMERIC(12, 2);
END;
$$;


-- Question 8 (c)
CREATE OR REPLACE PROCEDURE pr_enroll_student(
    p_course_id    INT,
    p_student_name VARCHAR(120),
    p_enrolled_on  DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_seats   INT;
    v_active_cnt  INT;
    v_student     VARCHAR(120) := btrim(p_student_name);
    v_enrolled_on DATE := COALESCE(p_enrolled_on, CURRENT_DATE);
BEGIN
    IF v_student IS NULL OR v_student = '' THEN
        RAISE EXCEPTION 'Student name cannot be empty.';
    END IF;

    SELECT max_seats
    INTO v_max_seats
    FROM courses
    WHERE course_id = p_course_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown course_id (%): course does not exist.', p_course_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM enrollments
        WHERE course_id = p_course_id
          AND lower(student_name) = lower(v_student)
          AND status IN ('ENROLLED', 'COMPLETED')
    ) THEN
        RAISE EXCEPTION 'Student (%) is already actively enrolled in course_id (%).',
            v_student, p_course_id;
    END IF;

    SELECT COUNT(*)::INT
    INTO v_active_cnt
    FROM enrollments
    WHERE course_id = p_course_id
      AND status IN ('ENROLLED', 'COMPLETED');

    IF v_active_cnt >= v_max_seats THEN
        RAISE EXCEPTION 'Course (%) has reached maximum seat capacity (%).',
            p_course_id, v_max_seats;
    END IF;

    INSERT INTO enrollments (course_id, student_name, enrolled_on, status)
    VALUES (p_course_id, v_student, v_enrolled_on, 'ENROLLED');
END;
$$;


-- Question 8 (d)
CREATE OR REPLACE FUNCTION fn_trg_courses_fee_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.credit_fee IS DISTINCT FROM OLD.credit_fee THEN
        INSERT INTO fee_rate_audit (course_id, old_fee, new_fee, changed_at)
        VALUES (NEW.course_id, OLD.credit_fee, NEW.credit_fee, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_courses_after_update_credit_fee
AFTER UPDATE OF credit_fee ON courses
FOR EACH ROW
WHEN (OLD.credit_fee IS DISTINCT FROM NEW.credit_fee)
EXECUTE FUNCTION fn_trg_courses_fee_audit();


-- Question 8 (a) - Enrollments loaded via pr_enroll_student
CALL pr_enroll_student(1, 'Chanda Mwamba', DATE '2026-11-20');
CALL pr_enroll_student(1, 'Mutale Banda',  DATE '2026-11-21');
CALL pr_enroll_student(1, 'Bwalya Phiri',  DATE '2026-11-22');
CALL pr_enroll_student(2, 'Mwape Tembo',   DATE '2026-11-22');
CALL pr_enroll_student(2, 'Luyando Zulu',  DATE '2026-11-23');
CALL pr_enroll_student(3, 'Kabwe Lungu',   DATE '2026-11-24');


-- Question 8 (e)
CREATE OR REPLACE VIEW v_course_seat_availability AS
SELECT
    c.course_id,
    c.course_code,
    c.course_title,
    c.max_seats,
    COUNT(e.enrollment_id) FILTER (WHERE e.status IN ('ENROLLED', 'COMPLETED'))::INT AS seats_taken,
    (c.max_seats - COUNT(e.enrollment_id) FILTER (WHERE e.status IN ('ENROLLED', 'COMPLETED')))::INT AS seats_open
FROM courses c
LEFT JOIN enrollments e ON e.course_id = c.course_id
GROUP BY c.course_id, c.course_code, c.course_title, c.max_seats
ORDER BY seats_open ASC, c.course_code;

SELECT * FROM v_course_seat_availability;


-- Question 8 (f)
-- Composite index on (course_id, enrolled_on) accelerates filtering by course
-- and scanning enrollment dates; INCLUDE (student_name, status) supports
-- index-only access for roster and status queries.
CREATE INDEX idx_enrollments_course_enrolled_on
ON enrollments (course_id, enrolled_on)
INCLUDE (student_name, status);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    enrollment_id,
    student_name,
    enrolled_on,
    status
FROM enrollments
WHERE course_id = 1
  AND enrolled_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-24'
ORDER BY enrolled_on;


-- Question 8 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_enrollment_summary(
    p_day DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, CURRENT_DATE);
BEGIN
    INSERT INTO daily_enrollment_summary (summary_date, active_count, projected_rev)
    SELECT
        v_target_day AS summary_date,
        COUNT(e.enrollment_id) FILTER (WHERE e.status IN ('ENROLLED', 'COMPLETED'))::INT AS active_count,
        COALESCE(SUM(c.credit_fee) FILTER (WHERE e.status IN ('ENROLLED', 'COMPLETED')), 0.00) AS projected_rev
    FROM enrollments e
    JOIN courses c ON c.course_id = e.course_id
    WHERE e.enrolled_on <= v_target_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        active_count  = EXCLUDED.active_count,
        projected_rev = EXCLUDED.projected_rev;
END;
$$;

-- Daily schedule at 00:15 for CURRENT_DATE: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_enrollment_summary(CURRENT_DATE);"

CALL pr_refresh_enrollment_summary(DATE '2026-11-24');
CALL pr_refresh_enrollment_summary(DATE '2026-11-24');
SELECT * FROM daily_enrollment_summary;