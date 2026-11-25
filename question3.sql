-- ============================================================================
-- Question 3
-- ============================================================================

-- Question 3 (a)
CREATE TABLE books (
    book_id       SERIAL PRIMARY KEY,
    book_title    VARCHAR(150) NOT NULL,
    daily_fine    NUMERIC(8, 2) NOT NULL CHECK (daily_fine > 0),
    copies_avail  INT NOT NULL CHECK (copies_avail >= 0)
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    member_name   VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL DEFAULT CURRENT_DATE,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE fine_audit (
    audit_id      SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    old_fine      NUMERIC(8, 2) NOT NULL,
    new_fine      NUMERIC(8, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (book_title, daily_fine, copies_avail) VALUES
    ('Database System Concepts',          5.00, 3),
    ('Operating System Concepts',         4.00, 5),
    ('Computer Networks',                 3.50, 4);


-- Question 3 (b)
CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INT,
    p_as_of   DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on        DATE;
    v_returned_on   DATE;
    v_daily_fine    NUMERIC(8, 2);
    v_as_of         DATE := COALESCE(p_as_of, CURRENT_DATE);
    v_effective_end DATE;
    v_late_days     INT;
BEGIN
    SELECT l.due_on, l.returned_on, b.daily_fine
    INTO v_due_on, v_returned_on, v_daily_fine
    FROM loans l
    JOIN books b ON b.book_id = l.book_id
    WHERE l.loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id (%): loan does not exist.', p_loan_id;
    END IF;

    v_effective_end := COALESCE(v_returned_on, v_as_of);

    IF v_effective_end <= v_due_on THEN
        RETURN 0.00;
    END IF;

    v_late_days := (v_effective_end - v_due_on);
    RETURN (v_late_days * v_daily_fine)::NUMERIC(10, 2);
END;
$$;


-- Question 3 (c)
CREATE OR REPLACE PROCEDURE pr_borrow_book(
    p_book_id     INT,
    p_member_name VARCHAR(100),
    p_borrowed_on DATE DEFAULT CURRENT_DATE,
    p_due_on      DATE DEFAULT (CURRENT_DATE + INTERVAL '14 days')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_copies_avail INT;
    v_borrowed_on  DATE := COALESCE(p_borrowed_on, CURRENT_DATE);
    v_due_on       DATE := COALESCE(p_due_on, (COALESCE(p_borrowed_on, CURRENT_DATE) + INTERVAL '14 days')::DATE);
BEGIN
    IF p_member_name IS NULL OR btrim(p_member_name) = '' THEN
        RAISE EXCEPTION 'Member name cannot be empty.';
    END IF;

    IF v_due_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Invalid dates: due_on (%) cannot be earlier than borrowed_on (%).',
            v_due_on, v_borrowed_on;
    END IF;

    SELECT copies_avail
    INTO v_copies_avail
    FROM books
    WHERE book_id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown book_id (%): book does not exist.', p_book_id;
    END IF;

    IF v_copies_avail <= 0 THEN
        RAISE EXCEPTION 'No copies available for book_id (%).', p_book_id;
    END IF;

    INSERT INTO loans (book_id, member_name, borrowed_on, due_on, returned_on)
    VALUES (p_book_id, btrim(p_member_name), v_borrowed_on, v_due_on, NULL);

    UPDATE books
    SET copies_avail = copies_avail - 1
    WHERE book_id = p_book_id;
END;
$$;


-- Question 3 (d)
CREATE OR REPLACE FUNCTION fn_trg_books_fine_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.daily_fine IS DISTINCT FROM OLD.daily_fine THEN
        INSERT INTO fine_audit (book_id, old_fine, new_fine, changed_at)
        VALUES (NEW.book_id, OLD.daily_fine, NEW.daily_fine, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_books_after_update_daily_fine
AFTER UPDATE OF daily_fine ON books
FOR EACH ROW
WHEN (OLD.daily_fine IS DISTINCT FROM NEW.daily_fine)
EXECUTE FUNCTION fn_trg_books_fine_audit();


-- Question 3 (a) - Loans loaded via pr_borrow_book
CALL pr_borrow_book(1, 'Chanda Mwamba', DATE '2026-11-01', DATE '2026-11-10');
CALL pr_borrow_book(1, 'Mutale Banda',  DATE '2026-11-03', DATE '2026-11-12');
CALL pr_borrow_book(2, 'Bwalya Phiri',  DATE '2026-11-05', DATE '2026-11-15');
CALL pr_borrow_book(2, 'Mwape Tembo',   DATE '2026-11-10', DATE '2026-11-20');
CALL pr_borrow_book(3, 'Luyando Zulu',  DATE '2026-11-12', DATE '2026-11-26');
CALL pr_borrow_book(3, 'Kabwe Lungu',   DATE '2026-11-15', DATE '2026-11-29');

UPDATE loans
SET returned_on = DATE '2026-11-14'
WHERE loan_id = 1;


-- Question 3 (e)
CREATE OR REPLACE VIEW v_active_overdue_loans AS
SELECT
    l.loan_id,
    l.member_name,
    b.book_title,
    l.borrowed_on,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS accrued_fine
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE
ORDER BY l.due_on ASC, l.loan_id;

SELECT * FROM v_active_overdue_loans;


-- Question 3 (f)
-- Composite index on (book_id, due_on) supports filtering by a specific book
-- and scanning due dates within a range; INCLUDE (member_name, returned_on)
-- satisfies common loan lookups without extra heap fetches.
CREATE INDEX idx_loans_book_due_on
ON loans (book_id, due_on)
INCLUDE (member_name, returned_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    loan_id,
    member_name,
    borrowed_on,
    due_on,
    returned_on
FROM loans
WHERE book_id = 1
  AND due_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-24'
ORDER BY due_on;


-- Question 3 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_as_of DATE := COALESCE(p_as_of, CURRENT_DATE);
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT
        v_as_of AS snapshot_date,
        COUNT(*)::INT AS overdue_count,
        COALESCE(SUM(fn_loan_fine(loan_id, v_as_of)), 0.00) AS total_fine
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < v_as_of
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Daily schedule at 00:10 for CURRENT_DATE: 10 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_overdue(CURRENT_DATE);"

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;