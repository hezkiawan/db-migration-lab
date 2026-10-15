-- M2.2 (Option C, step 2): create log_activity as a PARTITIONED table on the TARGET.
-- Run against target/appdb. Keys and indexes are added AFTER loading (m2_4_finish.sql),
-- because building an index once on loaded data is faster than updating it row by row.
\set ON_ERROR_STOP on
-- Month boundaries are defined in UTC (same as the copy script). Decide this explicitly in production.
SET TIME ZONE 'UTC';

-- PostgreSQL 16 does NOT allow identity columns on partitioned tables
-- (support was added in PostgreSQL 17, see its release notes).
-- So instead of "GENERATED ALWAYS AS IDENTITY" we use a plain sequence as the default.
CREATE SEQUENCE log_activity_id_seq AS bigint;

CREATE TABLE log_activity (
    id           bigint      NOT NULL DEFAULT nextval('log_activity_id_seq'),
    user_id      bigint      NOT NULL,
    action       text        NOT NULL,
    entity_type  text,
    entity_id    bigint,
    ip_address   inet,
    user_agent   text,
    metadata     jsonb,
    created_at   timestamptz NOT NULL          -- the partition key must never be NULL
) PARTITION BY RANGE (created_at);              -- one partition per month, by created_at

ALTER SEQUENCE log_activity_id_seq OWNED BY log_activity.id;   -- dropping the table drops the sequence

-- One partition per month: the 24 months of data + 2 FUTURE months (pre-created, like pg_partman "premake").
-- Names look like log_activity_y2026m10. Range = FROM first day (included) TO next first day (excluded).
DO $$
DECLARE
    m      date := (date_trunc('month', now()) - interval '23 months')::date;
    last_m date := (date_trunc('month', now()) + interval '2 months')::date;
BEGIN
    WHILE m <= last_m LOOP
        EXECUTE format('CREATE TABLE %I PARTITION OF log_activity FOR VALUES FROM (%L) TO (%L)',
                       'log_activity_' || to_char(m, '"y"YYYY"m"MM'),
                       m, (m + interval '1 month')::date);
        m := (m + interval '1 month')::date;
    END LOOP;
END $$;

-- Safety net: rows that fit no monthly partition land here instead of failing the INSERT.
-- It should stay EMPTY; rows here mean "a future partition was not created in time".
CREATE TABLE log_activity_default PARTITION OF log_activity DEFAULT;

\d+ log_activity
