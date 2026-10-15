-- db-migration-lab — M0 step 3: schema (tables only, no data yet)
-- A mini "chat platform" DB: 3 normal tables + 1 giant log table.
-- Secondary indexes (and log_activity's primary key) are added AFTER loading data,
-- because the Postgres docs say building an index on existing data is faster
-- than updating it row by row during the load (docs: "Populating a Database").

-- 1) users: who uses the app (small)
CREATE TABLE users (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- auto-numbered 1,2,3...
    name        text        NOT NULL,
    email       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 2) conversations: one chat thread between a customer and the business (small)
CREATE TABLE conversations (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     bigint      NOT NULL REFERENCES users(id),        -- foreign key: must point to a real user
    channel     text        NOT NULL,                             -- e.g. 'whatsapp', 'web'
    status      text        NOT NULL,                             -- e.g. 'open', 'closed'
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- 3) messages: the chat messages (medium)
CREATE TABLE messages (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id bigint      NOT NULL REFERENCES conversations(id),
    sender          text        NOT NULL,                         -- 'customer' or 'agent'
    body            text        NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- 4) log_activity: every action anyone does — the GIANT table (~90% of the DB)
--    No foreign keys on purpose: log tables are usually written very often and kept
--    loosely coupled (this also keeps M2 partitioning simpler).
--    Primary key is added after the load (see 03_indexes.sql).
CREATE TABLE log_activity (
    id           bigint GENERATED ALWAYS AS IDENTITY,  -- integer key: pgcopydb needs one to split the table
    user_id      bigint      NOT NULL,
    action       text        NOT NULL,                 -- e.g. 'login', 'send_message'
    entity_type  text,                                 -- e.g. 'conversation'
    entity_id    bigint,
    ip_address   inet,                                 -- Postgres type for IP addresses
    user_agent   text,
    metadata     jsonb,                                -- flexible extra details, like real logs
    created_at   timestamptz NOT NULL                  -- WHEN it happened: key for partitioning/TTL later
);
