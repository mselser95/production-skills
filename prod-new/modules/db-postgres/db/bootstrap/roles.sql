-- roles.sql — the role split, schema, grants and per-role limits. Idempotent.
-- Run as the bootstrap superuser against the application database.
--
-- Passwords come from the environment (\getenv); this file holds no secret.
\set ON_ERROR_STOP on

-- Keep passwords out of the server log: no statement logging, and do not echo
-- the failing statement on error, for this session only.
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;

\getenv migrator_pw DB_MIGRATOR_PASSWORD
\getenv app_pw      DB_APP_PASSWORD
\getenv readonly_pw DB_READONLY_PASSWORD
\getenv monitor_pw  DB_MONITOR_PASSWORD

SELECT NOT (:{?migrator_pw} AND :{?app_pw} AND :{?readonly_pw} AND :{?monitor_pw}) AS missing \gset
\if :missing
  \echo 'roles.sql: DB_MIGRATOR_PASSWORD, DB_APP_PASSWORD, DB_READONLY_PASSWORD and DB_MONITOR_PASSWORD must all be set'
  DO $$ BEGIN RAISE EXCEPTION 'role passwords missing from the environment'; END $$;
\endif
SELECT (:'migrator_pw' = '' OR :'app_pw' = '' OR :'readonly_pw' = '' OR :'monitor_pw' = '') AS empty \gset
\if :empty
  DO $$ BEGIN RAISE EXCEPTION 'a role password is empty'; END $$;
\endif

SELECT current_database() AS db \gset

-- ---- roles ------------------------------------------------------------------
-- Create what is missing, then ALTER with the full attribute list so a re-run
-- also repairs drift.
SELECT format('CREATE ROLE %I', r)
  FROM unnest(ARRAY['app_owner', 'app_migrator', 'app_rw', 'app_ro', 'app_monitor']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- owner: owns the schema and what is created as it; cannot log in.
ALTER ROLE app_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
-- migrator: DDL in the app schema, only for CI/deploy.
ALTER ROLE app_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 5 PASSWORD :'migrator_pw';
-- app: DML only.
ALTER ROLE app_rw LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 50 PASSWORD :'app_pw';
-- read-only.
ALTER ROLE app_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 20 PASSWORD :'readonly_pw';
-- monitoring: pg_monitor and nothing else.
ALTER ROLE app_monitor LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 5 PASSWORD :'monitor_pw';

-- Memberships. The migrator inherits the owner so it can `SET ROLE app_owner`
-- for owner-owned objects. Nobody else is a member of anything but the
-- monitor of pg_monitor.
GRANT app_owner TO app_migrator WITH INHERIT TRUE, SET TRUE;
GRANT pg_monitor TO app_monitor;

-- ---- database and schemas --------------------------------------------------
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO app_migrator, app_rw, app_ro, app_monitor;

-- No object creation in public for anyone but its owner (no-op on a fresh 18
-- cluster, protective on a database cloned from an older template).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_owner;
ALTER SCHEMA app OWNER TO app_owner;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA app TO app_migrator;
GRANT USAGE ON SCHEMA app TO app_rw, app_ro;

-- Tables and sequences created later by the migrator or the owner carry the
-- right grants without a per-migration GRANT.
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA app
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA app
  GRANT SELECT ON SEQUENCES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT SELECT ON SEQUENCES TO app_ro;

-- ---- per-role settings: fixed search_path and timeouts ----------------------
-- app: short. A request that needs longer is a bug to see, not to wait out.
ALTER ROLE app_rw SET search_path = app;
ALTER ROLE app_rw SET statement_timeout = '5s';
ALTER ROLE app_rw SET lock_timeout = '2s';
ALTER ROLE app_rw SET idle_in_transaction_session_timeout = '10s';
-- read-only: reports may run longer than requests.
ALTER ROLE app_ro SET search_path = app;
ALTER ROLE app_ro SET statement_timeout = '30s';
ALTER ROLE app_ro SET lock_timeout = '2s';
ALTER ROLE app_ro SET idle_in_transaction_session_timeout = '30s';
-- migrator and owner: long statements (index builds, backfills), but a short
-- lock_timeout so a migration never queues behind traffic and blocks it.
ALTER ROLE app_migrator SET search_path = app;
ALTER ROLE app_migrator SET statement_timeout = '10min';
ALTER ROLE app_migrator SET lock_timeout = '5s';
ALTER ROLE app_migrator SET idle_in_transaction_session_timeout = '5min';
ALTER ROLE app_owner SET search_path = app;
ALTER ROLE app_owner SET statement_timeout = '10min';
ALTER ROLE app_owner SET lock_timeout = '5s';
ALTER ROLE app_owner SET idle_in_transaction_session_timeout = '5min';
-- monitoring: quick, and it reads public (where the statistics views live).
ALTER ROLE app_monitor SET search_path = public;
ALTER ROLE app_monitor SET statement_timeout = '5s';
ALTER ROLE app_monitor SET lock_timeout = '1s';
ALTER ROLE app_monitor SET idle_in_transaction_session_timeout = '10s';
