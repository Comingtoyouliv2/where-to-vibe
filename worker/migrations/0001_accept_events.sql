-- Accepted-advice event log.
-- One row per Tab-accept: what the user originally wrote -> the advice they
-- accepted, plus light context, so we can analyze which advice users find
-- useful. Anonymous: device_id is a random per-install UUID, no account/PII.
CREATE TABLE IF NOT EXISTS accept_events (
  id              TEXT PRIMARY KEY,   -- server-generated UUID
  device_id       TEXT NOT NULL,      -- random per-install id (anonymous)
  original_input  TEXT,               -- what the user had written
  accepted_advice TEXT,               -- the advice text they accepted (copied)
  reason          TEXT,               -- the coach's "why" shown on page 0
  user_level      TEXT,               -- beginner / intermediate / advanced
  stage           TEXT,               -- idea / mvp / spec / ...
  language        TEXT,               -- english / korean
  app_name        TEXT,               -- frontmost app the draft was in
  created_at      TEXT NOT NULL       -- ISO-8601 timestamp (server clock)
);

CREATE INDEX IF NOT EXISTS idx_accept_events_device ON accept_events(device_id);
CREATE INDEX IF NOT EXISTS idx_accept_events_created ON accept_events(created_at);
