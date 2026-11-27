-- 99-final.sql: runs last of the init files (the Timescale variant adds 30-*).
-- Defence in depth for pg_stat_statements: roles.sql already keeps the init
-- session out of the statistics, and no cleartext password is in SQL text at
-- all; this drops whatever the init phase recorded (including the verifiers'
-- ALTER ROLE statements, if tracking was on) before the real server starts,
-- so the statistics file saved at shutdown starts empty.
SELECT pg_stat_statements_reset();
