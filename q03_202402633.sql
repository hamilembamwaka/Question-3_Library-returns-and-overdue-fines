-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student: Mwaka Hamilemba | Student No: 202402633

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Operating System Concepts');

-- Six loans: open overdue, on-time return, late return, open not yet due, ...
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Alice Zulu',    CURRENT_DATE - 30, CURRENT_DATE - 16, NULL,              0),  -- open, overdue 16 days
    (1, 'Brian Tembo',   CURRENT_DATE - 25, CURRENT_DATE - 11, CURRENT_DATE - 11, 0),  -- returned ON the due date
    (2, 'Chanda Lungu',  CURRENT_DATE - 20, CURRENT_DATE - 6,  CURRENT_DATE - 3,  6),  -- returned 3 days late = K6
    (2, 'Dalitso Moyo',  CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL,              0),  -- open, not yet due
    (3, 'Esther Kunda',  CURRENT_DATE - 15, CURRENT_DATE - 1,  NULL,              0),  -- open, overdue 1 day
    (3, 'Felix Mumba',   CURRENT_DATE - 12, CURRENT_DATE + 2,  NULL,              0);  -- open, will be returned on time

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- earlier of as-of date and return date (if there is one)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);    -- K2 per overdue day, never negative
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    -- return date and final fine are stored together in ONE statement
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loans_returned_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loans_returned_audit();

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
CALL pr_return_loan(1, CURRENT_DATE);          -- 16 days late = K32
CALL pr_return_loan(6, CURRENT_DATE);          -- on time = K0
SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;    -- two rows only
UPDATE loans SET fine_amount = fine_amount WHERE loan_id = 2;  -- no returned_on change -> no audit row
SELECT COUNT(*) AS audit_rows FROM loan_audit;
DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(1, CURRENT_DATE);   -- already returned
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(4, CURRENT_DATE - 100);  -- before borrowed_on
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index ----------------------------------------------------------------
-- Searching "unreturned loans of one book": a PARTIAL index on book_id that only
-- contains rows where returned_on IS NULL stays small (returned loans are the
-- majority over time) and matches the query exactly.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM loans WHERE book_id = 2 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned on that date
      AND due_on < p_as_of                                 -- and past due
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;

-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_overdue_daily', '10 0 * * *',
        $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
