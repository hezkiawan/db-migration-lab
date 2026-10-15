-- M3.1: hand log_activity over to pg_partman (partition maintenance + retention)
-- Run on TARGET/appdb. Requires the target image with pg_partman + pg_cron and
-- shared_preload_libraries = 'pg_cron' (see docker/target.Dockerfile, docker-compose.yml).
-- On Azure the same is done via Server parameters (shared_preload_libraries, azure.extensions) + restart.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';            -- pg_partman docs: run maintenance with a consistent (UTC) time zone

CREATE SCHEMA IF NOT EXISTS partman; -- month boundaries in UTC, same as M2
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman; -- install the cabinet manager (own schema = tidy)
CREATE EXTENSION IF NOT EXISTS pg_cron;          -- pg_cron lives in the database named by cron.database_name

-- 1) pg_partman finds child tables BY NAME (<parent>_pYYYYMMDD for time ranges).
--    Our M2 names were log_activity_yYYYYmMM, so rename them to the pg_partman convention,
--    otherwise pg_partman would try to create overlapping partitions.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid -- "list every child table of log_activity"
           WHERE i.inhparent = 'public.log_activity'::regclass 
             AND c.relname ~ '^log_activity_y[0-9]{4}m[0-9]{2}$'  -- only the y2024m11-style names
  LOOP
    EXECUTE format('ALTER TABLE public.%I RENAME TO %I', r.relname,
      'log_activity_p' || substr(r.relname, 15, 4) || substr(r.relname, 20, 2) || '01');
  END LOOP;
END $$;

-- 2) Register the partition set. create_parent() exists in pg_partman 5.0 – 5.5
--    (5.5 adds create_partition() as the new name; Azure PG16 ships 5.4.3).
SELECT partman.create_parent(
    p_parent_table    := 'public.log_activity', -- which table
    p_control         := 'created_at',          -- which column decides the month
    p_interval        := '1 month',             -- drawer size
    p_premake         := 3,                     -- always keep 3 future months ready
    p_start_partition := (SELECT min(created_at) FROM public.log_activity)::text,
    p_default_table   := false                  -- we already have log_activity_default (M2)
);

-- 3) Retention = the TTL for the HOT data in the database.
--    Partitions holding only data older than 12 months are DETACHED (not dropped)
--    and moved to schema "archive", where our archive job exports them (M3.2).
CREATE SCHEMA IF NOT EXISTS archive;
UPDATE partman.part_config
   SET retention            = '12 months',      -- older than this → remove from the cabinet
       retention_keep_table = true, --          -- DETACH, don't DROP (we want to archive first!)
       retention_schema     = 'archive',        -- put pulled-out drawers in schema "archive"
       infinite_time_partitions = true          -- keep creating future partitions even if no new data arrives
 WHERE parent_table = 'public.log_activity';

-- 4) Evidence table for ISO 27001 8.10 / UU PDP: what was archived/deleted, when, by whom.
CREATE TABLE IF NOT EXISTS public.archive_log (
    partition_name  text        PRIMARY KEY,
    row_count       bigint      NOT NULL,
    min_created_at  timestamptz,
    max_created_at  timestamptz,
    file_name       text        NOT NULL,
    file_bytes      bigint      NOT NULL,
    sha256          text        NOT NULL,
    archived_at     timestamptz NOT NULL DEFAULT now(),
    archived_by     text        NOT NULL DEFAULT current_user
);

-- 5) Schedule maintenance (creates future partitions + applies retention) every day at 01:00 UTC.
SELECT cron.schedule('partman-maintenance', '0 1 * * *', $$CALL partman.run_maintenance_proc()$$);

-- Show the result
SELECT parent_table, control, partition_interval, premake, retention, retention_keep_table, retention_schema
FROM partman.part_config;
SELECT jobid, jobname, schedule, command FROM cron.job;
