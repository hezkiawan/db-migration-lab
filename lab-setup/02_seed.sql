-- db-migration-lab — M0 steps 4-5: fill the tables with fake data
-- Run with psql. Size of the giant table is controlled by one variable:
--   psql ... -v rows_per_month=1250000 -f /lab/lab-setup/02_seed.sql
-- 24 months x rows_per_month rows go into log_activity.
-- Default 1,250,000/month = 30M rows ≈ 7-8 GB (about 1/10 of the real 80 GB DB).

\timing on
\set ON_ERROR_STOP on

-- default value if you didn't pass -v rows_per_month=...
\if :{?rows_per_month}
\else
  \set rows_per_month 1250000
\endif

-- psql variables can't be read inside a DO block, so store it as a session setting
SELECT set_config('lab.rows_per_month', :'rows_per_month', false);

-- ---------------------------------------------------------------
-- Step 4: small tables (one INSERT ... SELECT each = fast, set-based)
-- generate_series(1, N) makes N rows; we build fake values from it.
-- ---------------------------------------------------------------

-- 50,000 users
INSERT INTO users (name, email, created_at)
SELECT 'user_' || g,
       'user_' || g || '@example.com',
       now() - random() * interval '730 days'          -- created sometime in the last 2 years
FROM generate_series(1, 50000) AS g;

-- 200,000 conversations, each belongs to a random existing user
INSERT INTO conversations (user_id, channel, status, created_at)
SELECT 1 + floor(random() * 50000)::bigint,
       (ARRAY['whatsapp','web','instagram','messenger'])[1 + floor(random() * 4)::int],
       (ARRAY['open','pending','closed'])[1 + floor(random() * 3)::int],
       now() - random() * interval '730 days'
FROM generate_series(1, 200000) AS g;

-- 2,000,000 messages, each in a random existing conversation
INSERT INTO messages (conversation_id, sender, body, created_at)
SELECT 1 + floor(random() * 200000)::bigint,
       (ARRAY['customer','agent'])[1 + floor(random() * 2)::int],
       md5(random()::text) || ' ' || md5(random()::text),   -- ~65 chars of fake text
       now() - random() * interval '730 days'
FROM generate_series(1, 2000000) AS g;

-- ---------------------------------------------------------------
-- Step 5: the giant log_activity table, one month at a time
-- Why month by month?
--   * each month is its own transaction (COMMIT), so a failure loses one month, not everything
--   * we see progress (RAISE NOTICE)
--   * it mirrors how real logs grow: a steady stream over time
-- ---------------------------------------------------------------
DO $$
DECLARE
    n           int  := current_setting('lab.rows_per_month')::int;
    first_month date := date_trunc('month', now())::date - interval '23 months';
    m_start     timestamptz;
    m_end       timestamptz;
BEGIN
    FOR m IN 0..23 LOOP
        m_start := first_month + make_interval(months => m);
        m_end   := m_start + interval '1 month';

        INSERT INTO log_activity
            (user_id, action, entity_type, entity_id, ip_address, user_agent, metadata, created_at)
        SELECT
            1 + floor(random() * 50000)::bigint,
            (ARRAY['login','logout','view_conversation','send_message',
                   'assign_agent','close_conversation','export_report'])[1 + floor(random() * 7)::int],
            'conversation',
            1 + floor(random() * 200000)::bigint,
            ('10.' || floor(random()*256)::int || '.' || floor(random()*256)::int
                   || '.' || floor(random()*256)::int)::inet,
            (ARRAY['Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/129.0',
                   'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1',
                   'Dart/3.5 (dart:io) KouventaMobile/2.4.1'])[1 + floor(random() * 3)::int],
            jsonb_build_object('session', md5(random()::text),
                               'latency_ms', floor(random() * 500)::int,
                               'ok', random() > 0.02),
            m_start + random() * (m_end - m_start)      -- random moment inside this month
        FROM generate_series(1, n);

        COMMIT;   -- allowed in a DO block run outside an explicit transaction (PG 11+)
        RAISE NOTICE 'month % of 24 done (%)', m + 1, to_char(m_start, 'YYYY-MM');
    END LOOP;
END $$;
