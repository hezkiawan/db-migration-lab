-- Same "last 7 days" query on the SOURCE (unpartitioned) table, for comparison.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM log_activity WHERE created_at >= now() - interval '7 days';
