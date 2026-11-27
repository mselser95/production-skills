-- Timescale variant only (compose.timescale.yml mounts this file).
-- The image's own init script already installs the extension in template1 and
-- the application database; this makes the requirement explicit and idempotent.
CREATE EXTENSION IF NOT EXISTS timescaledb;
