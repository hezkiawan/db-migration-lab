-- db-migration-lab — M0: indexes AFTER the data load (faster than indexing row by row)
\timing on
\set ON_ERROR_STOP on

-- more memory for index builds in this session only (docs: increase maintenance_work_mem)
SET maintenance_work_mem = '1GB';

-- log_activity: integer primary key (pgcopydb needs a unique integer key to split the table;
-- online migration needs a primary key on every table)
ALTER TABLE log_activity     ADD PRIMARY KEY (id);

-- the "when" column: real apps filter logs by time; M2 (partitioning) and M3 (TTL) use it
CREATE INDEX log_activity_created_at_idx ON log_activity (created_at);

-- indexes on foreign-key columns (Postgres does NOT create these automatically)
CREATE INDEX conversations_user_id_idx    ON conversations (user_id);
CREATE INDEX messages_conversation_id_idx ON messages (conversation_id);

-- refresh planner statistics after a bulk load (docs: "Run ANALYZE afterwards")
ANALYZE;
