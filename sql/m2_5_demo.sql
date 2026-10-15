-- M2.5 demo (run on TARGET): where do rows go, and what does a query read?
\set ON_ERROR_STOP on

-- 1) Routing: insert test rows WITHOUT an id (the app's normal INSERT) and show which partition got them.
--    tableoid::regclass = the actual partition that stores the row. ROLLBACK keeps the data clean.
BEGIN;
INSERT INTO log_activity (user_id, action, created_at) VALUES (1, 'demo: now',          now())                       RETURNING id, created_at, tableoid::regclass AS stored_in;
INSERT INTO log_activity (user_id, action, created_at) VALUES (1, 'demo: next month',   now() + interval '1 month')  RETURNING id, created_at, tableoid::regclass AS stored_in;
INSERT INTO log_activity (user_id, action, created_at) VALUES (1, 'demo: next year',    now() + interval '1 year')   RETURNING id, created_at, tableoid::regclass AS stored_in;
ROLLBACK;

-- 2) Partition pruning: a "last 7 days" query only touches the newest partition(s).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM log_activity WHERE created_at >= now() - interval '7 days';


