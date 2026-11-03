\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Dropping an extension needs no privileges on extension_drop's registration table, for the three commands
 * the trigger fires for, whether or not the extension is registered. Also covered: registered SQL runs as
 * the dropping role, XD001 for a stale registration (and its text), and drops involving no extension. Each
 * scenario ends with ROLLBACK TO SAVEPOINT base; the file's single open transaction makes that possible.
 */
SELECT plan(
  4 -- setup, table privileges
  + 8 -- DROP SCHEMA CASCADE and DROP OWNED BY, registered and not
  + 5 -- DROP EXTENSION by the owner
  + 4 -- registered SQL's own error, stale registration
  + 5 -- XD001 text
  + 6 -- drops involving no extension
  + 6 -- claim outside the trigger, temp table of the same name
  + 2 -- member functions
  + 10 -- planted operators

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

\set DROP_SCHEMA 'SELECT pg_temp.xd_as(''extension_drop_test_plain'', ''DROP SCHEMA extension_drop_test_plain_schema CASCADE'')'
\set DROP_OWNED 'SELECT pg_temp.xd_as(''extension_drop_test_plain'', ''DROP OWNED BY extension_drop_test_plain CASCADE'')'
\set DROP_EXTENSION 'SELECT pg_temp.xd_as(''extension_drop_test_owner'', ''DROP EXTENSION extension_drop_test'')'
-- extension_drop's member functions (pg_depend, deptype = 'e')
\set MEMBER_FUNCS 'SELECT p.proname, p.prosecdef, p.proconfig FROM pg_depend d JOIN pg_proc p ON p.oid = d.objid WHERE d.classid = ''pg_proc''::regclass AND d.refclassid = ''pg_extension''::regclass AND d.deptype = ''e'' AND d.refobjid = (SELECT e.oid FROM pg_extension e WHERE e.extname = ''extension_drop'')'
\set RECREATE 'CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain; CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema'
\set UNREGISTER 'SELECT ' :"extension_drop_schema" '.extension_drop__remove(''extension_drop_test'')'
\set CAPTURE_XD001 'SELECT message, detail, hint FROM pg_temp.xd_capture(%L, ''XD001'')'
\set SANITY_ASSERT 'SELECT ' :"extension_drop_schema" '.extension_drop__sanity_assert()'

-- The registered SQL, as the three statements the tests below need it in
SELECT format($$SELECT %I.extension_drop__update('extension_drop_test', %L)$$
    , :'extension_drop_schema', $s$SELECT set_config('extension_drop_test.ran_as', current_user, false)$s$) AS "RECORD_ROLE" \gset
SELECT format($$SELECT %I.extension_drop__update('extension_drop_test', 'CREATE ROLE extension_drop_test_never')$$
    , :'extension_drop_schema') AS "NEEDS_CREATEROLE" \gset
SELECT format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$
    , :'extension_drop_schema') AS "INSERT_STALE" \gset

DO $$ BEGIN PERFORM set_config('extension_drop_test.ran_as', 'none', false); END $$;

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_plain'
  , 'Create non-superuser role'
);
-- Created as superuser, so the role only owns the schema
SELECT lives_ok(
  :'RECREATE'
  , 'Create schema owned by role containing a registered extension'
);
SELECT lives_ok(
  :'RECORD_ROLE'
  , 'Register SQL that records current_user'
);
SELECT table_privs_are(
  :'extension_drop_schema', 'extension_drop__commands', 'extension_drop_test_plain', '{}'::name[]
  , 'The role has no privileges on extension_drop__commands'
);

SAVEPOINT base;

-- Registered: the SQL runs as the dropping role and the registration is gone
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Registered: DROP SCHEMA CASCADE with no table privileges'
);
SELECT is(
  current_setting('extension_drop_test.ran_as')
  , 'extension_drop_test_plain'
  , 'Registered SQL ran as the dropping role'
);
SELECT is_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands$$, :'extension_drop_schema')
  , 'Registration removed'
);
ROLLBACK TO SAVEPOINT base;

SELECT lives_ok(
  :'DROP_OWNED'
  , 'Registered: DROP OWNED BY with no table privileges'
);
SELECT is(
  current_setting('extension_drop_test.ran_as')
  , 'extension_drop_test_plain'
  , 'Registered SQL ran as the dropping role'
);
SELECT is_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands$$, :'extension_drop_schema')
  , 'Registration removed'
);
ROLLBACK TO SAVEPOINT base;

-- Unregistered
SELECT lives_ok(
  :'UNREGISTER' || '; ' || :'DROP_SCHEMA'
  , 'Unregistered: DROP SCHEMA CASCADE with no table privileges'
);
ROLLBACK TO SAVEPOINT base;
SELECT lives_ok(
  :'UNREGISTER' || '; ' || :'DROP_OWNED'
  , 'Unregistered: DROP OWNED BY with no table privileges'
);
ROLLBACK TO SAVEPOINT base;

-- DROP EXTENSION needs the extension's owner; create it as a role that is then demoted
DROP SCHEMA extension_drop_test_plain_schema CASCADE;
CREATE ROLE extension_drop_test_owner SUPERUSER;
SELECT lives_ok(
  $$SELECT pg_temp.xd_as('extension_drop_test_owner', 'CREATE EXTENSION extension_drop_test')$$
  , 'Create registered test extension as role'
);
SELECT lives_ok(
  :'RECORD_ROLE' || '; ALTER ROLE extension_drop_test_owner NOSUPERUSER'
  , 'Register the recording SQL and demote the role'
);
SAVEPOINT owned;
SELECT lives_ok(
  :'DROP_EXTENSION'
  , 'Registered: DROP EXTENSION by the extension''s non-superuser owner with no table privileges'
);
SELECT is(
  current_setting('extension_drop_test.ran_as')
  , 'extension_drop_test_owner'
  , 'Registered SQL ran as the dropping role'
);
ROLLBACK TO SAVEPOINT owned;
SELECT lives_ok(
  :'UNREGISTER' || '; ' || :'DROP_EXTENSION'
  , 'Unregistered: DROP EXTENSION by the extension''s non-superuser owner with no table privileges'
);
ROLLBACK TO SAVEPOINT base;

-- A privilege error from the registered SQL itself surfaces unchanged
SELECT lives_ok(
  :'NEEDS_CREATEROLE'
  , 'Register SQL that needs CREATEROLE'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , '42501'
  , 'permission denied to create role'
  , 'Registered SQL''s own privilege error surfaces unchanged'
);
ROLLBACK TO SAVEPOINT base;

-- A stale registration fails the drop whether or not the extension is registered
SELECT throws_ok(
  :'INSERT_STALE' || '; ' || :'DROP_SCHEMA'
  , 'XD001'
  , 'unexpected drop commands'
  , 'Registered: DROP SCHEMA CASCADE with a stale registration present'
);
ROLLBACK TO SAVEPOINT base;
SELECT throws_ok(
  :'UNREGISTER' || '; ' || :'INSERT_STALE' || '; ' || :'DROP_SCHEMA'
  , 'XD001'
  , 'unexpected drop commands'
  , 'Unregistered: DROP SCHEMA CASCADE with a stale registration present'
);
ROLLBACK TO SAVEPOINT base;

/*
 * Every path that raises XD001 gives the same message, DETAIL and HINT: sanity_assert, which both
 * extension_drop__get() and the event trigger (via extension_drop__claim) raise from.
 */
SELECT lives_ok(:'INSERT_STALE', 'Insert a stale registration');
SELECT results_eq(
  format(:'CAPTURE_XD001', :'SANITY_ASSERT')
  , $$VALUES (
    'unexpected drop commands'
    , 'This extension does not exist: extension_drop_test_stale'
    , E'This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.\n  Use SELECT extension_drop__repair() to fix this.')$$
  , 'sanity_assert raises XD001 with the expected message, DETAIL and HINT'
);
SELECT results_eq(
  format(:'CAPTURE_XD001', 'DROP EXTENSION extension_drop_test')
  , format(:'CAPTURE_XD001', :'SANITY_ASSERT')
  , 'The event trigger raises the same message, DETAIL and HINT'
);
SELECT lives_ok(
  replace(:'INSERT_STALE', 'extension_drop_test_stale', 'extension_drop_test_stale2')
  , 'Insert a second stale registration'
);
-- Names come out in no particular order
SELECT matches(
  (SELECT detail FROM pg_temp.xd_capture(:'SANITY_ASSERT', 'XD001'))
  , '^These extensions do not exist: (extension_drop_test_stale, extension_drop_test_stale2|extension_drop_test_stale2, extension_drop_test_stale)$'
  , 'Plural DETAIL names both stale extensions'
);
ROLLBACK TO SAVEPOINT base;

/*
 * Drops involving no extension must not depend on the caller's privileges or on the state of
 * extension_drop__commands.
 */
SELECT lives_ok(
  :'UNREGISTER' || '; DROP EXTENSION extension_drop_test'
  , 'Drop the extension so the drops below involve none'
);
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_unrelated AUTHORIZATION extension_drop_test_plain
      CREATE TABLE t(i int);
    SELECT pg_temp.xd_as('extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_unrelated CASCADE')$$
  , 'Non-superuser DROP SCHEMA CASCADE of a schema with no extension'
);
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_unrelated AUTHORIZATION extension_drop_test_plain
      CREATE TABLE t(i int);
    SELECT pg_temp.xd_as('extension_drop_test_plain', 'DROP OWNED BY extension_drop_test_plain')$$
  , 'Non-superuser DROP OWNED BY with no extension'
);
SELECT lives_ok(:'INSERT_STALE', 'Insert a stale registration');
SELECT results_eq(
  format($$SELECT %I.extension_drop__sanity_check()$$, :'extension_drop_schema')
  , $$SELECT '{extension_drop_test_stale}'::name[]$$
  , 'Stale registration is present'
);
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_su_schema; DROP SCHEMA extension_drop_test_su_schema$$
  , 'Superuser DROP SCHEMA with stale registration'
);
ROLLBACK TO SAVEPOINT base;

-- Called directly, claim must delete nothing: pg_event_trigger_dropped_objects() refuses outside the trigger
SELECT throws_ok(
  format('SELECT * FROM %I.extension_drop__claim()', :'extension_drop_schema')
  , '39P03'
  , 'pg_event_trigger_dropped_objects() can only be called in a sql_drop event trigger function'
  , 'extension_drop__claim outside the event trigger fails'
);
SELECT throws_ok(
  format('SELECT pg_temp.xd_as(''extension_drop_test_plain'', %L)', format('SELECT %I.extension_drop__claim()', :'extension_drop_schema'))
  , '39P03'
  , 'pg_event_trigger_dropped_objects() can only be called in a sql_drop event trigger function'
  , 'extension_drop__claim outside the event trigger fails for a plain role'
);
SELECT isnt_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands WHERE extension_name = 'extension_drop_test'$$, :'extension_drop_schema')
  , 'The extension is still registered'
);

-- A temp table named like ours must not hide the real registration from claim
SELECT lives_ok(
  $$SELECT pg_temp.xd_as('extension_drop_test_plain', 'CREATE TEMP TABLE extension_drop__commands(extension_name name, sql text); DROP SCHEMA extension_drop_test_plain_schema CASCADE')$$
  , 'DROP SCHEMA CASCADE by a role that has a temp table of the same name'
);
SELECT is(
  current_setting('extension_drop_test.ran_as')
  , 'extension_drop_test_plain'
  , 'The registered SQL still ran'
);
SELECT is_empty(
  format($$SELECT 1 FROM %I.extension_drop__commands$$, :'extension_drop_schema')
  , 'The real registration was removed'
);
ROLLBACK TO SAVEPOINT base;

/*
 * Every function runs with a pinned search_path, and only extension_drop__claim is SECURITY DEFINER (so
 * the event trigger, and everything it runs, is the dropping role's own).
 */
/*
 * Not functions_are(): in existing mode the schema may hold other objects.
 * Matching (name, prosecdef) rows makes an added overload or definer function fail.
 */
SELECT bag_eq(
  $$SELECT proname, prosecdef FROM ($$ || :'MEMBER_FUNCS' || $$) m$$
  , $$VALUES ('extension_drop__sanity_check', false), ('extension_drop__sanity_assert', false), ('extension_drop__repair', false)
    , ('extension_drop__get', false), ('extension_drop__add', false), ('extension_drop__remove', false)
    , ('extension_drop__update', false), ('extension_drop__event_trigger', false), ('extension_drop__usage_guard', false)
    , ('extension_drop__claim', true)$$
  , 'extension_drop''s member functions are exactly these, and only extension_drop__claim is SECURITY DEFINER'
);
-- pgTAP has no assertion for proconfig
SELECT is_empty(
  $$SELECT proname FROM ($$ || :'MEMBER_FUNCS' || $$) m WHERE proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']$$
  , 'Every extension_drop function pins search_path to pg_catalog, pg_temp'
);

/*
 * A role with CREATE on extension_drop's schema must not be able to run code as anyone who calls into it.
 * The planted operators are on the types the functions actually compare (name, name) and (name, text);
 * an exact match in the schema beats pg_catalog's for any function whose path puts the schema first.
 */
SELECT format('SELECT pg_temp.xd_as(''extension_drop_test_plain'', %L)', format($q$
    CREATE FUNCTION %1$I.xd_test_hijack(name, name) RETURNS boolean LANGUAGE plpgsql AS
      $f$ BEGIN PERFORM set_config('extension_drop_test.hijacked', 'yes', false); RETURN true; END $f$;
    CREATE FUNCTION %1$I.xd_test_hijack(name, text) RETURNS boolean LANGUAGE plpgsql AS
      $f$ BEGIN PERFORM set_config('extension_drop_test.hijacked', 'yes', false); RETURN true; END $f$;
    CREATE OPERATOR %1$I.= (LEFTARG = name, RIGHTARG = name, FUNCTION = %1$I.xd_test_hijack(name, name));
    CREATE OPERATOR %1$I.= (LEFTARG = name, RIGHTARG = text, FUNCTION = %1$I.xd_test_hijack(name, text));
    CREATE OPERATOR %1$I.<> (LEFTARG = name, RIGHTARG = name, FUNCTION = %1$I.xd_test_hijack(name, name));
    CREATE OPERATOR %1$I.<> (LEFTARG = name, RIGHTARG = text, FUNCTION = %1$I.xd_test_hijack(name, text));
  $q$, :'extension_drop_schema')) AS "PLANT" \gset
SELECT format('GRANT CREATE ON SCHEMA %I TO extension_drop_test_plain', :'extension_drop_schema') AS "GRANT_CREATE" \gset

SELECT lives_ok(
  :'GRANT_CREATE' || '; ' || :'PLANT' || $$; SELECT set_config('extension_drop_test.hijacked', 'no', false)$$
  , 'Grant CREATE on extension_drop''s schema and plant = and <> operators on (name, name) and (name, text)'
);
SELECT lives_ok(
  :'DROP_SCHEMA'
  , 'Registered: DROP SCHEMA CASCADE by the role with the operators planted'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'The claim function did not run the planted operators'
);
ROLLBACK TO SAVEPOINT base;

-- With a stale row claim runs sanity_assert as the owner; the planted operators still must not run
SELECT lives_ok(
  :'GRANT_CREATE' || '; ' || :'PLANT' || '; ' || :'INSERT_STALE' || $$; SELECT set_config('extension_drop_test.hijacked', 'no', false)$$
  , 'Plant the operators and insert a stale registration'
);
SELECT throws_ok(
  :'DROP_SCHEMA'
  , 'XD001'
  , 'unexpected drop commands'
  , 'DROP SCHEMA CASCADE with a stale registration: XD001'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'Neither the claim function (as owner) nor sanity_assert (as owner) ran the planted operators'
);

-- The invoker paths run with the caller's own rights, so a superuser is the interesting caller
SELECT lives_ok(
  format($$DELETE FROM %I.extension_drop__commands WHERE extension_name = 'extension_drop_test_stale'$$, :'extension_drop_schema')
  , 'Remove the stale registration'
);
SELECT lives_ok(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , 'extension_drop__get as superuser, which runs sanity_assert'
);
SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , 'Superuser drop of a registered extension, which runs the event trigger'
);
SELECT is(
  current_setting('extension_drop_test.hijacked')
  , 'no'
  , 'The invoker paths did not run the planted operators'
);
ROLLBACK TO SAVEPOINT base;

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
