-- The isolated dev runtime currently authenticates as aisl_app. Its migrations
-- need ownership of existing dev tables, not just CONNECT or table DML grants.
-- Inherit the existing dev owner only after proving it has no wider authority.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$
DECLARE owner_id oid; database_id oid;
BEGIN
  SELECT oid INTO STRICT owner_id FROM pg_roles
    WHERE rolname = 'aisl_dev' AND NOT rolsuper AND NOT rolcreaterole
      AND NOT rolcreatedb AND NOT rolreplication AND NOT rolbypassrls;
  SELECT oid INTO STRICT database_id FROM pg_database
    WHERE datname = 'aisl_dev' AND datdba = owner_id;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aisl_app' AND rolinherit
      AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb
      AND NOT rolreplication AND NOT rolbypassrls) THEN
    RAISE EXCEPTION 'Unexpected application role privileges';
  END IF;
  IF EXISTS (SELECT FROM pg_auth_members WHERE member = owner_id) THEN
    RAISE EXCEPTION 'Dev owner inherits another role; review before granting';
  END IF;
  IF EXISTS (SELECT FROM pg_shdepend WHERE refclassid = 'pg_authid'::regclass
      AND refobjid = owner_id AND dbid <> database_id
      AND NOT (dbid = 0 AND classid = 'pg_database'::regclass
               AND objid = database_id AND deptype = 'o')) THEN
    RAISE EXCEPTION 'Dev owner has dependencies outside aisl_dev';
  END IF;
END $$;
GRANT aisl_dev TO aisl_app;
COMMIT;
