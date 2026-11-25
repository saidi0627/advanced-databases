-- ============================================================================
-- Question 6
-- ============================================================================

-- Question 6 (a)
CREATE TABLE accounts (
    account_id    SERIAL PRIMARY KEY,
    account_holder VARCHAR(120) NOT NULL,
    balance       NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (balance >= 0),
    daily_limit   NUMERIC(12, 2) NOT NULL CHECK (daily_limit > 0)
);

CREATE TABLE transactions (
    tx_id         SERIAL PRIMARY KEY,
    account_id    INT NOT NULL REFERENCES accounts(account_id),
    tx_type       VARCHAR(15) NOT NULL CHECK (tx_type IN ('DEPOSIT', 'WITHDRAWAL')),
    amount        NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    tx_date       DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE limit_audit (
    audit_id      SERIAL PRIMARY KEY,
    account_id    INT NOT NULL REFERENCES accounts(account_id),
    old_limit     NUMERIC(12, 2) NOT NULL,
    new_limit     NUMERIC(12, 2) NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_account_summary (
    summary_date  DATE PRIMARY KEY,
    total_deposits    NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (total_deposits >= 0),
    total_withdrawals NUMERIC(14, 2) NOT NULL DEFAULT 0.00 CHECK (total_withdrawals >= 0)
);

INSERT INTO accounts (account_holder, balance, daily_limit) VALUES
    ('Chanda Mwamba', 15000.00, 5000.00),
    ('Mutale Banda',   8500.00, 3000.00),
    ('Bwalya Phiri',  22000.00, 7500.00);


-- Question 6 (b)
CREATE OR REPLACE FUNCTION fn_daily_withdrawal_remaining(
    p_account_id INT,
    p_day        DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_day        DATE := COALESCE(p_day, CURRENT_DATE);
    v_limit      NUMERIC(12, 2);
    v_withdrawn  NUMERIC(12, 2);
BEGIN
    SELECT daily_limit
    INTO v_limit
    FROM accounts
    WHERE account_id = p_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown account_id (%): account does not exist.', p_account_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
    INTO v_withdrawn
    FROM transactions
    WHERE account_id = p_account_id
      AND tx_type = 'WITHDRAWAL'
      AND tx_date = v_day;

    RETURN GREATEST(v_limit - v_withdrawn, 0.00);
END;
$$;


-- Question 6 (c)
CREATE OR REPLACE PROCEDURE pr_record_transaction(
    p_account_id INT,
    p_tx_type    VARCHAR(15),
    p_amount     NUMERIC(12, 2),
    p_tx_date    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance     NUMERIC(12, 2);
    v_daily_limit NUMERIC(12, 2);
    v_withdrawn   NUMERIC(12, 2);
    v_tx_type     VARCHAR(15) := upper(btrim(p_tx_type));
    v_tx_date     DATE := COALESCE(p_tx_date, CURRENT_DATE);
BEGIN
    IF v_tx_type NOT IN ('DEPOSIT', 'WITHDRAWAL') THEN
        RAISE EXCEPTION 'Invalid transaction type (%): must be DEPOSIT or WITHDRAWAL.', p_tx_type;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount (%): amount must be greater than zero.', p_amount;
    END IF;

    SELECT balance, daily_limit
    INTO v_balance, v_daily_limit
    FROM accounts
    WHERE account_id = p_account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown account_id (%): account does not exist.', p_account_id;
    END IF;

    IF v_tx_type = 'DEPOSIT' THEN
        INSERT INTO transactions (account_id, tx_type, amount, tx_date)
        VALUES (p_account_id, 'DEPOSIT', p_amount, v_tx_date);

        UPDATE accounts
        SET balance = balance + p_amount
        WHERE account_id = p_account_id;
    ELSE
        IF v_balance < p_amount THEN
            RAISE EXCEPTION 'Insufficient funds for account_id (%): balance %, requested %.',
                p_account_id, v_balance, p_amount;
        END IF;

        SELECT COALESCE(SUM(amount), 0.00)
        INTO v_withdrawn
        FROM transactions
        WHERE account_id = p_account_id
          AND tx_type = 'WITHDRAWAL'
          AND tx_date = v_tx_date;

        IF v_withdrawn + p_amount > v_daily_limit THEN
            RAISE EXCEPTION 'Daily withdrawal limit exceeded for account_id (%): limit %, already withdrawn %, requested %.',
                p_account_id, v_daily_limit, v_withdrawn, p_amount;
        END IF;

        INSERT INTO transactions (account_id, tx_type, amount, tx_date)
        VALUES (p_account_id, 'WITHDRAWAL', p_amount, v_tx_date);

        UPDATE accounts
        SET balance = balance - p_amount
        WHERE account_id = p_account_id;
    END IF;
END;
$$;


-- Question 6 (d)
CREATE OR REPLACE FUNCTION fn_trg_accounts_limit_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.daily_limit IS DISTINCT FROM OLD.daily_limit THEN
        INSERT INTO limit_audit (account_id, old_limit, new_limit, changed_at)
        VALUES (NEW.account_id, OLD.daily_limit, NEW.daily_limit, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_after_update_daily_limit
AFTER UPDATE OF daily_limit ON accounts
FOR EACH ROW
WHEN (OLD.daily_limit IS DISTINCT FROM NEW.daily_limit)
EXECUTE FUNCTION fn_trg_accounts_limit_audit();


-- Question 6 (a) - Transactions loaded via pr_record_transaction
CALL pr_record_transaction(1, 'WITHDRAWAL', 1500.00, DATE '2026-11-22');
CALL pr_record_transaction(1, 'DEPOSIT',    3000.00, DATE '2026-11-23');
CALL pr_record_transaction(2, 'WITHDRAWAL', 1200.00, DATE '2026-11-23');
CALL pr_record_transaction(2, 'DEPOSIT',    2000.00, DATE '2026-11-24');
CALL pr_record_transaction(3, 'WITHDRAWAL', 2500.00, DATE '2026-11-23');
CALL pr_record_transaction(3, 'WITHDRAWAL', 1500.00, DATE '2026-11-24');


-- Question 6 (e)
CREATE OR REPLACE VIEW v_low_balance_accounts AS
SELECT
    account_id,
    account_holder,
    balance,
    daily_limit
FROM accounts
WHERE balance < 10000.00
ORDER BY balance ASC, account_holder;

SELECT * FROM v_low_balance_accounts;


-- Question 6 (f)
-- Composite index on (account_id, tx_date) supports equality filtering by
-- account and range scans on tx_date; INCLUDE (tx_type, amount) allows
-- index-only scans for transaction summaries.
CREATE INDEX idx_transactions_account_tx_date
ON transactions (account_id, tx_date)
INCLUDE (tx_type, amount);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    tx_id,
    tx_type,
    amount,
    tx_date
FROM transactions
WHERE account_id = 1
  AND tx_date BETWEEN DATE '2026-11-22' AND DATE '2026-11-24'
ORDER BY tx_date;


-- Question 6 (g)
CREATE OR REPLACE PROCEDURE pr_refresh_account_summary(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
BEGIN
    INSERT INTO daily_account_summary (summary_date, total_deposits, total_withdrawals)
    SELECT
        v_target_day AS summary_date,
        COALESCE(SUM(amount) FILTER (WHERE tx_type = 'DEPOSIT'), 0.00)    AS total_deposits,
        COALESCE(SUM(amount) FILTER (WHERE tx_type = 'WITHDRAWAL'), 0.00) AS total_withdrawals
    FROM transactions
    WHERE tx_date = v_target_day
    ON CONFLICT (summary_date)
    DO UPDATE SET
        total_deposits    = EXCLUDED.total_deposits,
        total_withdrawals = EXCLUDED.total_withdrawals;
END;
$$;

-- Daily schedule at 00:15 for previous day: 15 0 * * *
-- Run via Windows Task Scheduler:
-- "C:\Program Files\PostgreSQL\16\bin\psql.exe" -U postgres -d your_db -c "CALL pr_refresh_account_summary((CURRENT_DATE - INTERVAL '1 day')::DATE);"

CALL pr_refresh_account_summary(DATE '2026-11-23');
CALL pr_refresh_account_summary(DATE '2026-11-23');
SELECT * FROM daily_account_summary;