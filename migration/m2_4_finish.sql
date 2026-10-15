-- M2.4 (Option C, step 4): after ALL months are copied, on the TARGET.
\set ON_ERROR_STOP on
\timing on
SET maintenance_work_mem = '1GB';

-- Primary key on a partitioned table MUST include the partition key (created_at).
-- Postgres builds one matching index on every partition.
ALTER TABLE log_activity ADD PRIMARY KEY (id, created_at);
CREATE INDEX log_activity_created_at_idx ON log_activity (created_at);

-- Sequence hand-over: new rows must continue AFTER the highest copied id,
-- otherwise the next INSERT would reuse id 1, 2, 3 ...
SELECT setval('log_activity_id_seq', (SELECT max(id) FROM log_activity)) AS sequence_now_at;

ANALYZE log_activity;
