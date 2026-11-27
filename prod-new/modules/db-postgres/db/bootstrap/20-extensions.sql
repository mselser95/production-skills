-- Extensions that must exist before migrations. Idempotent.
-- pg_stat_statements needs shared_preload_libraries (conf/postgresql.conf).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
