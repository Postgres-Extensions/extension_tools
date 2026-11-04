\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Dropping an extension needs no privileges on extension_drop's registration table, for the three commands
 * the trigger fires for, whether or not the extension is registered. Also covered: registered SQL runs as
 * the dropping role, XD001 for a stale registration (and its text), drops involving no extension, and
 * the planted-operator attack on the dropping function. Scenarios are grouped by the state they need;
 * pg_temp.xd_scenario rolls back whatever each one does.
 */
SELECT plan(
  1 -- table privileges
  + 9 -- DROP SCHEMA CASCADE and DROP OWNED BY, registered SQL's error, stale registration
  + 3 -- XD001 text
  + 2 -- temp table of the same name
  + 1 -- dropping function outside the trigger
  + 6 -- planted operators
  + 2 -- member functions
  + 3 -- DROP EXTENSION by the owner
  + 4 -- drops involving no extension

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

/*
 * Optionally unregister (unreg), insert a stale registration (stale) and run setup (as the current role;
 * @S@ is extension_drop's schema), then run drop_sql as role (the current role if NULL) and check it
 * succeeds, or fails with state and msg. ran_as checks the registered SQL ran as that role and the
 * registration is gone; hijack checks the planted operators did not run. Everything is rolled back.
 */
CREATE FUNCTION pg_temp.xd_scenario(
  descr text, role name, drop_sql text
  , unreg boolean DEFAULT false, stale boolean DEFAULT false, setup text DEFAULT ''
  , state text DEFAULT NULL, msg text DEFAULT NULL
  , ran_as name DEFAULT NULL, hijack boolean DEFAULT false
) RETURNS SETOF text LANGUAGE plpgsql AS $f$
DECLARE
  sch text := quote_ident((SELECT n.nspname FROM pg_extension x JOIN pg_namespace n ON n.oid = x.extnamespace
                            WHERE x.extname = 'extension_drop'));
  run text := replace(drop_sql, '@S@', sch);
  remaining int;
  actual text := '';
  expected text := '';
BEGIN
  IF role IS NOT NULL THEN
    run := format('SELECT pg_temp.xd_as(%L, %L)', role, run);
  END IF;
  PERFORM set_config('extension_drop_test.ran_as', 'none', false), set_config('extension_drop_test.hijacked', 'no', false);
  BEGIN
    IF unreg THEN
      EXECUTE format('SELECT %s.extension_drop__remove(''extension_drop_test'')', sch);
    END IF;
    IF stale THEN
      EXECUTE format('INSERT INTO %s.extension_drop__commands VALUES(''extension_drop_test_stale'', ''SELECT 1'')', sch);
    END IF;
    IF setup <> '' THEN
      EXECUTE replace(setup, '@S@', sch);
    END IF;

    IF state IS NULL THEN
      RETURN NEXT lives_ok(run, descr);
    ELSE
      RETURN NEXT throws_ok(run, state, msg, descr);
    END IF;

    IF ran_as IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM %s.extension_drop__commands', sch) INTO remaining;
      actual := format('ran as %s, %s registrations left', current_setting('extension_drop_test.ran_as'), remaining);
      expected := format('ran as %s, 0 registrations left', ran_as);
    END IF;
    IF hijack THEN
      actual := actual || ' hijacked=' || current_setting('extension_drop_test.hijacked');
      expected := expected || ' hijacked=no';
    END IF;
    IF expected <> '' THEN
      RETURN NEXT is(actual, expected, descr || ': effects');
    END IF;

    RAISE EXCEPTION 'rollback' USING ERRCODE = 'XD999';
  EXCEPTION WHEN SQLSTATE 'XD999' THEN
    NULL;
  END;
END $f$;

CREATE TEMP VIEW xd_members AS
  SELECT p.proname, p.prosecdef, p.proconfig
  FROM pg_depend d JOIN pg_proc p ON p.oid = d.objid
  WHERE d.classid = 'pg_proc'::regclass AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
    AND d.refobjid = (SELECT e.oid FROM pg_extension e WHERE e.extname = 'extension_drop');

\set REGISTER_RECORDER 'SELECT ' :"extension_drop_schema" '.extension_drop__update(''extension_drop_test'', $$SELECT set_config(''extension_drop_test.ran_as'', current_user, false)$$)' '\\g /dev/null'

CREATE ROLE extension_drop_test_plain;
-- Created as superuser, so the role only owns the schema
CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain;
CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_plain_schema;
:REGISTER_RECORDER

SELECT table_privs_are(
  :'extension_drop_schema', 'extension_drop__commands', 'extension_drop_test_plain', '{}'::name[]
  , 'The role has no privileges on extension_drop__commands'
);

-- Registered SQL runs as the dropping role and the registration is removed; unregistered drops just work
SELECT * FROM pg_temp.xd_scenario('Registered: DROP SCHEMA CASCADE with no table privileges'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , ran_as => 'extension_drop_test_plain');
SELECT * FROM pg_temp.xd_scenario('Registered: DROP OWNED BY with no table privileges'
  , 'extension_drop_test_plain', 'DROP OWNED BY extension_drop_test_plain CASCADE'
  , ran_as => 'extension_drop_test_plain');
SELECT * FROM pg_temp.xd_scenario('Unregistered: DROP SCHEMA CASCADE with no table privileges'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE', unreg => true);
SELECT * FROM pg_temp.xd_scenario('Unregistered: DROP OWNED BY with no table privileges'
  , 'extension_drop_test_plain', 'DROP OWNED BY extension_drop_test_plain CASCADE', unreg => true);

-- A privilege error from the registered SQL itself surfaces unchanged
SELECT * FROM pg_temp.xd_scenario('Registered SQL''s own privilege error surfaces unchanged'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , setup => $$SELECT @S@.extension_drop__update('extension_drop_test', 'CREATE ROLE extension_drop_test_never')$$
  , state => '42501', msg => 'permission denied to create role');

-- A stale registration fails the drop whether or not the extension is registered
SELECT * FROM pg_temp.xd_scenario('Registered: DROP SCHEMA CASCADE with a stale registration present'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , stale => true, state => 'XD001', msg => 'unexpected drop commands');
SELECT * FROM pg_temp.xd_scenario('Unregistered: DROP SCHEMA CASCADE with a stale registration present'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , unreg => true, stale => true, state => 'XD001', msg => 'unexpected drop commands');

/*
 * Every path that raises XD001 gives the same message, DETAIL and HINT: sanity_assert, which both
 * extension_drop__get() and the event trigger (via _extension_drop__dropping) raise from.
 */
SAVEPOINT stale;
INSERT INTO :"extension_drop_schema".extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1');
SELECT format('SELECT %I.extension_drop__sanity_assert()', :'extension_drop_schema') AS "SANITY_ASSERT" \gset
SELECT results_eq(
  format('SELECT message, detail, hint FROM pg_temp.xd_capture(%L, ''XD001'')', :'SANITY_ASSERT')
  , $$VALUES (
    'unexpected drop commands'
    , 'This extension does not exist: extension_drop_test_stale'
    , E'This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.\n  Use SELECT extension_drop__repair() to fix this.')$$
  , 'sanity_assert raises XD001 with the expected message, DETAIL and HINT'
);
SELECT results_eq(
  $$SELECT message, detail, hint FROM pg_temp.xd_capture('DROP EXTENSION extension_drop_test', 'XD001')$$
  , format('SELECT message, detail, hint FROM pg_temp.xd_capture(%L, ''XD001'')', :'SANITY_ASSERT')
  , 'The event trigger raises the same message, DETAIL and HINT'
);
INSERT INTO :"extension_drop_schema".extension_drop__commands VALUES('extension_drop_test_stale2', 'SELECT 1');
-- Names come out in no particular order
SELECT matches(
  (SELECT detail FROM pg_temp.xd_capture(:'SANITY_ASSERT', 'XD001'))
  , '^These extensions do not exist: (extension_drop_test_stale, extension_drop_test_stale2|extension_drop_test_stale2, extension_drop_test_stale)$'
  , 'Plural DETAIL names both stale extensions'
);
ROLLBACK TO SAVEPOINT stale;

-- A temp table named like ours must not hide the real registration from the dropping function
SELECT * FROM pg_temp.xd_scenario('A role with a temp table of the same name drops a registered extension'
  , 'extension_drop_test_plain'
  , 'CREATE TEMP TABLE extension_drop__commands(extension_name name, sql text); DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , ran_as => 'extension_drop_test_plain');

-- Called directly, the dropping function fails before deleting anything: pg_event_trigger_dropped_objects() refuses outside the trigger
SELECT * FROM pg_temp.xd_scenario('_extension_drop__dropping outside the event trigger fails for a plain role'
  , 'extension_drop_test_plain', 'SELECT @S@._extension_drop__dropping()'
  , state => '39P03', msg => 'pg_event_trigger_dropped_objects() can only be called in a sql_drop event trigger function');

/*
 * A role with CREATE on extension_drop's schema must not be able to run code as anyone who calls into it.
 * The planted operators are on the types the functions actually compare (name, name) and (name, text);
 * an exact match in the schema beats pg_catalog's for any function whose path puts the schema first.
 */
SAVEPOINT planted;
GRANT CREATE ON SCHEMA :"extension_drop_schema" TO extension_drop_test_plain;
SELECT format($q$
    CREATE FUNCTION %1$I.xd_test_hijack(name, name) RETURNS boolean LANGUAGE plpgsql AS
      $f$ BEGIN PERFORM set_config('extension_drop_test.hijacked', 'yes', false); RETURN true; END $f$;
    CREATE FUNCTION %1$I.xd_test_hijack(name, text) RETURNS boolean LANGUAGE plpgsql AS
      $f$ BEGIN PERFORM set_config('extension_drop_test.hijacked', 'yes', false); RETURN true; END $f$;
    CREATE OPERATOR %1$I.= (LEFTARG = name, RIGHTARG = name, FUNCTION = %1$I.xd_test_hijack(name, name));
    CREATE OPERATOR %1$I.= (LEFTARG = name, RIGHTARG = text, FUNCTION = %1$I.xd_test_hijack(name, text));
    CREATE OPERATOR %1$I.<> (LEFTARG = name, RIGHTARG = name, FUNCTION = %1$I.xd_test_hijack(name, name));
    CREATE OPERATOR %1$I.<> (LEFTARG = name, RIGHTARG = text, FUNCTION = %1$I.xd_test_hijack(name, text));
  $q$, :'extension_drop_schema') AS plant \gset
SELECT pg_temp.xd_as('extension_drop_test_plain', :'plant') \g /dev/null

SELECT * FROM pg_temp.xd_scenario('Registered: DROP SCHEMA CASCADE by the role with the operators planted'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE', hijack => true);
-- With a stale row the dropping function runs sanity_assert as the owner; the planted operators still must not run
SELECT * FROM pg_temp.xd_scenario('DROP SCHEMA CASCADE with a stale registration and the operators planted'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_plain_schema CASCADE'
  , stale => true, state => 'XD001', msg => 'unexpected drop commands', hijack => true);
-- The invoker paths run with the caller's own rights, so a superuser is the interesting caller
SELECT * FROM pg_temp.xd_scenario('Superuser extension_drop__get and drop of a registered extension with the operators planted'
  , NULL
  , $$SELECT * FROM @S@.extension_drop__get('extension_drop_test'); DROP SCHEMA extension_drop_test_plain_schema CASCADE$$
  , hijack => true);
ROLLBACK TO SAVEPOINT planted;

/*
 * Every function runs with a pinned search_path, and only _extension_drop__dropping is SECURITY DEFINER (so
 * the event trigger, and everything it runs, is the dropping role's own).
 * Not functions_are(): in existing mode the schema may hold other objects.
 * Matching (name, prosecdef) rows makes an added overload or definer function fail.
 */
SELECT bag_eq(
  'SELECT proname, prosecdef FROM pg_temp.xd_members'
  , $$VALUES ('extension_drop__sanity_check', false), ('extension_drop__sanity_assert', false), ('extension_drop__repair', false)
    , ('extension_drop__get', false), ('extension_drop__add', false), ('extension_drop__remove', false)
    , ('extension_drop__update', false), ('extension_drop__event_trigger', false), ('extension_drop__usage_guard', false)
    , ('_extension_drop__dropping', true)$$
  , 'extension_drop''s member functions are exactly these, and only _extension_drop__dropping is SECURITY DEFINER'
);
-- pgTAP has no assertion for proconfig
SELECT is_empty(
  $$SELECT proname FROM pg_temp.xd_members WHERE proconfig IS DISTINCT FROM ARRAY['search_path=pg_catalog, pg_temp']$$
  , 'Every extension_drop function pins search_path to pg_catalog, pg_temp'
);

-- DROP EXTENSION needs the extension's owner; create it as a role that is then demoted
DROP SCHEMA extension_drop_test_plain_schema CASCADE;
CREATE ROLE extension_drop_test_owner SUPERUSER;
SELECT pg_temp.xd_as('extension_drop_test_owner', 'CREATE EXTENSION extension_drop_test') \g /dev/null
:REGISTER_RECORDER
ALTER ROLE extension_drop_test_owner NOSUPERUSER;

SELECT * FROM pg_temp.xd_scenario('Registered: DROP EXTENSION by the extension''s non-superuser owner with no table privileges'
  , 'extension_drop_test_owner', 'DROP EXTENSION extension_drop_test'
  , ran_as => 'extension_drop_test_owner');
SELECT * FROM pg_temp.xd_scenario('Unregistered: DROP EXTENSION by the extension''s non-superuser owner with no table privileges'
  , 'extension_drop_test_owner', 'DROP EXTENSION extension_drop_test', unreg => true);

/*
 * Drops involving no extension must not depend on the caller's privileges or on the state of
 * extension_drop__commands.
 */
SELECT :"extension_drop_schema".extension_drop__remove('extension_drop_test') \g /dev/null
DROP EXTENSION extension_drop_test;
CREATE SCHEMA extension_drop_test_unrelated AUTHORIZATION extension_drop_test_plain CREATE TABLE t(i int);
INSERT INTO :"extension_drop_schema".extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1');
SELECT results_eq(
  format($$SELECT %I.extension_drop__sanity_check()$$, :'extension_drop_schema')
  , $$SELECT '{extension_drop_test_stale}'::name[]$$
  , 'Stale registration is present'
);
SELECT * FROM pg_temp.xd_scenario('Non-superuser DROP SCHEMA CASCADE of a schema with no extension'
  , 'extension_drop_test_plain', 'DROP SCHEMA extension_drop_test_unrelated CASCADE');
SELECT * FROM pg_temp.xd_scenario('Non-superuser DROP OWNED BY with no extension'
  , 'extension_drop_test_plain', 'DROP OWNED BY extension_drop_test_plain');
SELECT * FROM pg_temp.xd_scenario('Superuser DROP SCHEMA with stale registration'
  , NULL, 'CREATE SCHEMA extension_drop_test_su_schema; DROP SCHEMA extension_drop_test_su_schema');

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
