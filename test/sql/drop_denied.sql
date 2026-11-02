\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Dropping an extension that is registered with extension_drop needs access to
 * extension_drop's registration table; without it the caller must get an actionable
 * insufficient_privilege error, not a raw "permission denied for table". Dropping an
 * unregistered extension needs no table privileges, but a stale registration still fails.
 * Covers the three commands the trigger fires for.
 */
SELECT plan(
  2 -- Setup: role, schema with extension
  + 4 -- No table privileges: the error, then its DETAIL and HINT
  + 2 -- SELECT but not DELETE
  + 2 -- SELECT and DELETE, registered SQL fails with its own privilege error
  + 4 -- SELECT and DELETE, registered SQL succeeds
  + 1 -- Registration removed
  + 4 -- The same privileges held through a group role
  + 3 -- Unregistered, no table privileges: recreate, unregister, DROP SCHEMA CASCADE
  + 3 -- Unregistered, no table privileges: DROP OWNED BY
  + 5 -- Unregistered, SELECT but not DELETE
  + 6 -- Helper not executable: falls through to the caller's DELETE
  + 14 -- Planted operators in extension_drop's schema are not run by the helper or by a superuser's drops
  + 4 -- Temp table shadowing extension_drop__commands
  + 6 -- Stale registration
  + 4 -- DROP EXTENSION by a role that was a superuser when it created it
  + 2 -- DROP EXTENSION of an unregistered extension by that role
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

\set DROP_SCHEMA 'DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP SCHEMA extension_drop_test_plain_schema CASCADE; RESET ROLE; END $$'
\set DROP_OWNED 'DO $$ BEGIN SET LOCAL ROLE extension_drop_test_plain; DROP OWNED BY extension_drop_test_plain CASCADE; RESET ROLE; END $$'
\set RECREATE 'CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain; CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema'
\set UNREGISTER 'SELECT ' :"extension_drop_schema" '.extension_drop__remove(''extension_drop_test'')'
\set UNREGISTER_SU 'CREATE EXTENSION extension_drop_test; ' :UNREGISTER

-- The primary message names the table, its owner and the extensions being dropped
SELECT format(
  'permission denied for table "%s"."extension_drop__commands" (owned by role "%s"), which extension_drop needs to drop extension(s) "extension_drop_test"'
  , :'extension_drop_schema'
  , (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = format('%I.extension_drop__commands', :'extension_drop_schema')::regclass)
) AS "MSG" \gset

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_plain'
  , 'Create non-superuser role'
);
-- Created as superuser, so the role only owns the schema
SELECT lives_ok(
  :'RECREATE'
  , 'Create schema owned by role containing a registered extension'
);

SELECT throws_ok(
  :'DROP_SCHEMA'
  , '42501'
  , :'MSG'
  , 'Registered: DROP SCHEMA CASCADE with no table privileges'
);

-- The error text reaches the caller as DETAIL and HINT; stash them in GUCs to compare
SELECT lives_ok(
  $q$DO $$
  DECLARE d text; h text;
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.detail', d, false), set_config('extension_drop_test.hint', h, false);
  END $$$q$
  , 'Capture DETAIL and HINT'
);
SELECT is(
  current_setting('extension_drop_test.detail')
  , 'permission denied for table extension_drop__commands'
  , 'DETAIL is the original error'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , format(
      'Run the drop as role %1$I or a superuser, or grant SELECT, DELETE on %2$I.extension_drop__commands to the current role.'
      , current_user, :'extension_drop_schema')
  , 'HINT'
);

-- SELECT alone is not enough for a registered extension: the trigger deletes the registration
SELECT lives_ok(
  format('GRANT SELECT ON %I.extension_drop__commands TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Grant SELECT'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , '42501'
  , :'MSG'
  , 'Registered: DROP SCHEMA CASCADE with SELECT but not DELETE'
);

-- A privilege error from the registered SQL itself is not extension_drop's to translate
SELECT lives_ok(
  format($$GRANT DELETE ON %1$I.extension_drop__commands TO extension_drop_test_plain;
           SELECT %1$I.extension_drop__update('extension_drop_test', 'CREATE ROLE extension_drop_test_never')$$
    , :'extension_drop_schema')
  , 'Grant DELETE, register SQL that needs CREATEROLE'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , '42501'
  , 'permission denied to create role'
  , 'Registered SQL''s own privilege error surfaces unchanged'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Register harmless SQL'
);
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Registered: DROP SCHEMA CASCADE with the privileges the HINT names'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);
SELECT is_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands WHERE extension_name = 'extension_drop_test'$$, :'extension_drop_schema')
  , 'Registration removed'
);

-- Privileges held only through a group role the caller is a member of
SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the registered extension'
);
SELECT lives_ok(
  format(
    $$SELECT %1$I.extension_drop__update('extension_drop_test', 'SELECT 1');
      REVOKE SELECT, DELETE ON %1$I.extension_drop__commands FROM extension_drop_test_plain;
      CREATE ROLE extension_drop_test_group;
      GRANT SELECT, DELETE ON %1$I.extension_drop__commands TO extension_drop_test_group;
      GRANT extension_drop_test_group TO extension_drop_test_plain$$
    , :'extension_drop_schema')
  , 'Move the grants from the role to a group it belongs to'
);
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Registered: DROP SCHEMA CASCADE with the privileges held through a group role'
);
SELECT lives_ok(
  'REVOKE extension_drop_test_group FROM extension_drop_test_plain'
  , 'Remove all of the role''s access'
);

-- Unregistered extensions need no table privileges
SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the extension'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Unregistered: DROP SCHEMA CASCADE with no table privileges'
);

SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the extension'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  :'DROP_OWNED'
  , 'Unregistered: DROP OWNED BY with no table privileges'
);

SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the extension'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  format('GRANT SELECT ON %I.extension_drop__commands TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Grant SELECT'
);
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Unregistered: DROP SCHEMA CASCADE with SELECT but not DELETE'
);
SELECT lives_ok(
  format('REVOKE SELECT ON %I.extension_drop__commands FROM extension_drop_test_plain', :'extension_drop_schema')
  , 'Revoke SELECT'
);

-- With EXECUTE on the helper revoked, the trigger falls through to the caller's own DELETE
SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the extension'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  format('REVOKE EXECUTE ON FUNCTION %I.extension_drop__registered(name[]) FROM PUBLIC', :'extension_drop_schema')
  , 'Revoke EXECUTE on the helper'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , '42501'
  , :'MSG'
  , 'Unregistered: DROP SCHEMA CASCADE without EXECUTE on the helper or table privileges'
);
SELECT lives_ok(
  format('GRANT EXECUTE ON FUNCTION %I.extension_drop__registered(name[]) TO PUBLIC', :'extension_drop_schema')
  , 'Restore EXECUTE on the helper'
);
SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , 'Superuser drop schema'
);

/*
 * A role with CREATE on extension_drop's schema must not be able to run code as anyone who calls into it.
 * Exact name[] operators there would beat pg_catalog's polymorphic anyarray ones for any function whose
 * path includes the schema.
 */
SELECT lives_ok(
  format('GRANT CREATE ON SCHEMA %I TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Grant CREATE on extension_drop''s schema'
);
SELECT lives_ok(
  format($q$DO $d$
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    CREATE FUNCTION %1$I.xd_test_hijack(name[], name[]) RETURNS boolean LANGUAGE plpgsql AS
      $f$ BEGIN PERFORM set_config('extension_drop_test.hijacked', 'yes', false); RETURN true; END $f$;
    CREATE OPERATOR %1$I.= (LEFTARG = name[], RIGHTARG = name[], FUNCTION = %1$I.xd_test_hijack);
    CREATE OPERATOR %1$I.<> (LEFTARG = name[], RIGHTARG = name[], FUNCTION = %1$I.xd_test_hijack);
    RESET ROLE;
  END $d$$q$, :'extension_drop_schema')
  , 'Plant = and <> operators for name[] in extension_drop''s schema'
);
SELECT lives_ok(
  $$SELECT set_config('extension_drop_test.hijacked', 'no', false)$$
  , 'Reset the flag'
);
SELECT lives_ok(
  format($q$DO $d$
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    PERFORM %I.extension_drop__registered('{}');
    RESET ROLE;
  END $d$$q$, :'extension_drop_schema')
  , 'Call the helper as that role'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'The helper did not run the planted operators'
);

-- The invoker paths run with the caller's own rights, so a superuser is the interesting caller
SELECT lives_ok(
  $$CREATE EXTENSION extension_drop_test$$
  , 'Create a registered extension'
);
SELECT lives_ok(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , 'extension_drop__get as superuser, which runs sanity_assert'
);
SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test$$
  , 'Superuser DROP EXTENSION of a registered extension'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'The registered and get paths did not run the planted operators'
);
SELECT lives_ok(
  :'UNREGISTER_SU'
  , 'Create an extension and unregister it'
);
SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test$$
  , 'Superuser DROP EXTENSION of an unregistered extension'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'The unregistered path did not run the planted operators'
);

SELECT lives_ok(
  format('DROP OPERATOR %1$I.=(name[], name[]); DROP OPERATOR %1$I.<>(name[], name[]); DROP FUNCTION %1$I.xd_test_hijack(name[], name[])', :'extension_drop_schema')
  , 'Remove the planted operators'
);
SELECT lives_ok(
  format('REVOKE CREATE ON SCHEMA %I FROM extension_drop_test_plain', :'extension_drop_schema')
  , 'Revoke CREATE'
);

-- A temp table named like ours must not hide the real registration from the helper
SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the registered extension'
);
SELECT throws_ok(
  $q$DO $$
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    CREATE TEMP TABLE extension_drop__commands(extension_name name, sql text);
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
  END $$$q$
  , '42501'
  , :'MSG'
  , 'Registered extension is still found when the caller has a temp table of the same name'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , 'Superuser drop schema'
);

-- A stale registration must still fail the drop of an unregistered extension
SELECT lives_ok(
  :'RECREATE'
  , 'Recreate the extension'
);
SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert a stale registration'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , 'XD001'
  , 'unexpected drop commands'
  , 'Unregistered: DROP SCHEMA CASCADE with a stale registration present'
);
SELECT lives_ok(
  format('SELECT %I.extension_drop__repair()', :'extension_drop_schema')
  , 'Repair'
);
SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , 'Superuser drop schema'
);

-- ALTER EXTENSION can't change the owner, so create it as a role that is then demoted
SELECT lives_ok(
  'CREATE ROLE extension_drop_test_owner SUPERUSER'
  , 'Create role'
);
SELECT lives_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_owner; CREATE EXTENSION extension_drop_test; RESET ROLE; END $$$q$
  , 'Create test extension as role'
);
SELECT lives_ok(
  'ALTER ROLE extension_drop_test_owner NOSUPERUSER'
  , 'Demote role'
);
SELECT throws_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_owner; DROP EXTENSION extension_drop_test; END $$$q$
  , '42501'
  , :'MSG'
  , 'DROP EXTENSION by the extension''s non-superuser owner'
);

SELECT lives_ok(
  :'UNREGISTER'
  , 'Unregister the extension'
);
SELECT lives_ok(
  $q$DO $$ BEGIN SET LOCAL ROLE extension_drop_test_owner; DROP EXTENSION extension_drop_test; RESET ROLE; END $$$q$
  , 'Unregistered: DROP EXTENSION by the extension''s non-superuser owner with no table privileges'
);
SELECT is_empty(
  format($$SELECT unnest(%I.extension_drop__sanity_check())$$, :'extension_drop_schema')
  , 'No stale registration'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
