-- Shared team role definitions (instance-level, one copy per team).
-- gen-grants applies this before the per-database grant package, so CREATE
-- ROLE precedes the per-database GRANTs. Role assignment to members is done
-- by gen-grants (GRANT <role> TO 'member'@'ip'), never hardcoded here.
CREATE ROLE IF NOT EXISTS developer;
