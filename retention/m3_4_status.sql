-- M3.4: one-screen status of the hot/cold setup (run on TARGET/appdb)
\echo '== pg_partman configuration =='
SELECT parent_table, partition_interval, premake, retention, retention_keep_table, retention_schema
FROM partman.part_config;
\echo '== HOT: partitions still in the database (newest first) =='
SELECT c.relname AS partition, pg_get_expr(c.relpartbound, c.oid) AS bounds,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'public.log_activity'::regclass ORDER BY c.relname DESC;
\echo '== COLD: archived months (evidence log) =='
SELECT partition_name, row_count, pg_size_pretty(file_bytes) AS file_size, left(sha256, 12) AS sha256_start, archived_at
FROM public.archive_log ORDER BY partition_name;
\echo '== Scheduled jobs (pg_cron) =='
SELECT jobid, jobname, schedule, command, active FROM cron.job;
\echo '== Last job runs =='
SELECT jobid, status, start_time, end_time, left(return_message, 60) AS message
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
