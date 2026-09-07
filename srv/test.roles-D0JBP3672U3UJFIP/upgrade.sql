-- Per-database grants for `test`: privileges granted to the shared
-- `developer` role. {{dbname}} is filled by gen-grants from the target db.
GRANT SELECT, INSERT, UPDATE, DELETE ON {{dbname}}.* TO developer;
