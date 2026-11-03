\set ECHO none
\i test/pgxntool/setup.sql

/*
 * extension_drop resolves extension_drop__registered() as whichever role drops an extension, so PUBLIC
 * must keep USAGE on its schema: install and update refuse without it, REVOKE / DROP OWNED that would
 * remove it are rolled back (ddl_command_end), and every REVOKE / DROP OWNED is refused up front while
 * PUBLIC already lacks it (ddl_command_start).
 */
SELECT plan(
  1 -- Setup: role
  + 2 -- REVOKE USAGE FROM PUBLIC rejected, state unchanged
  + 4 -- REVOKE ALL FROM PUBLIC rejected, HINT/DETAIL capture and text
  + 1 -- REVOKE from a role other than PUBLIC
  + 3 -- DROP OWNED BY the grantor of PUBLIC's only USAGE
  + 6 -- Guard bypassed: REVOKE and DROP OWNED report the state, HINT capture and text, recovery
  + 1 -- Reinstall prerequisite: drop extension_drop
  + 3 -- Fresh install refused without PUBLIC USAGE: refused, HINT capture and text
  + 5 -- Update in a schema named x$body$y: refused, HINT capture and text, then succeeds
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT quote_ident(:'extension_drop_schema') AS qschema \gset

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_grantor'
  , 'Create role'
);

SELECT throws_ok(
  format('REVOKE USAGE ON SCHEMA %I FROM PUBLIC', :'extension_drop_schema')
  , '55000'
  , format('Command would remove PUBLIC''s USAGE on schema %s, which extension_drop requires', :'qschema')
  , 'REVOKE USAGE ON SCHEMA ... FROM PUBLIC is rejected'
);
SELECT is(
  has_schema_privilege('public', :'extension_drop_schema', 'USAGE')
  , true
  , 'PUBLIC still has USAGE'
);

SELECT throws_ok(
  format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', :'extension_drop_schema')
  , '55000'
  , format('Command would remove PUBLIC''s USAGE on schema %s, which extension_drop requires', :'qschema')
  , 'REVOKE ALL ON SCHEMA ... FROM PUBLIC is rejected'
);
SELECT lives_ok(
  format($q$DO $d$
  DECLARE h text; d text;
  BEGIN
    REVOKE USAGE ON SCHEMA %I FROM PUBLIC;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT, d = PG_EXCEPTION_DETAIL;
    PERFORM set_config('extension_drop_test.hint', h, false);
    PERFORM set_config('extension_drop_test.detail', d, false);
  END $d$$q$, :'extension_drop_schema')
  , 'Capture HINT and DETAIL'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , ''
  , 'No GRANT HINT: the command was prevented, nothing to fix'
);
SELECT is(
  current_setting('extension_drop_test.detail')
  , 'DDL command: REVOKE'
  , 'DETAIL names the command'
);

-- Only PUBLIC's USAGE matters
SELECT lives_ok(
  format('GRANT USAGE ON SCHEMA %1$I TO extension_drop_test_grantor; REVOKE USAGE ON SCHEMA %1$I FROM extension_drop_test_grantor', :'extension_drop_schema')
  , 'REVOKE from a role other than PUBLIC is allowed'
);

/*
 * PUBLIC's USAGE can survive a REVOKE by the owner because another role granted it too; DROP OWNED BY
 * that role then removes it.
 */
SELECT lives_ok(
  format($q$DO $d$
  BEGIN
    GRANT USAGE ON SCHEMA %1$I TO extension_drop_test_grantor WITH GRANT OPTION;
    SET LOCAL ROLE extension_drop_test_grantor;
    GRANT USAGE ON SCHEMA %1$I TO PUBLIC;
    RESET ROLE;
    REVOKE USAGE ON SCHEMA %1$I FROM PUBLIC;
  END $d$$q$, :'extension_drop_schema')
  , 'PUBLIC keeps USAGE through the grantor''s own grant'
);
SELECT throws_ok(
  'DROP OWNED BY extension_drop_test_grantor'
  , '55000'
  , format('Command would remove PUBLIC''s USAGE on schema %s, which extension_drop requires', :'qschema')
  , 'DROP OWNED BY the grantor of PUBLIC''s only USAGE is rejected'
);
SELECT lives_ok(
  format($q$GRANT USAGE ON SCHEMA %I TO PUBLIC; DROP OWNED BY extension_drop_test_grantor$q$, :'extension_drop_schema')
  , 'DROP OWNED BY the grantor is allowed once PUBLIC has USAGE from the owner'
);

/*
 * A superuser can bypass the guard; afterwards every REVOKE and DROP OWNED fails before running, naming the
 * state and the fix.
 */
SELECT lives_ok(
  format('SET LOCAL session_replication_role = replica; REVOKE USAGE ON SCHEMA %I FROM PUBLIC; RESET session_replication_role', :'extension_drop_schema')
  , 'Remove PUBLIC''s USAGE with event triggers bypassed'
);
SELECT throws_ok(
  format('REVOKE USAGE ON SCHEMA %I FROM extension_drop_test_grantor', :'extension_drop_schema')
  , '55000'
  , format('PUBLIC lacks USAGE on schema %s, which extension_drop requires', :'qschema')
  , 'An unrelated REVOKE reports the missing USAGE'
);
SELECT lives_ok(
  format($q$DO $d$
  DECLARE h text;
  BEGIN
    REVOKE USAGE ON SCHEMA %I FROM extension_drop_test_grantor;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.hint', h, false);
  END $d$$q$, :'extension_drop_schema')
  , 'Capture HINT'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , format('Run GRANT USAGE ON SCHEMA %s TO PUBLIC. extension_drop resolves extension_drop__registered() as whichever role drops an extension, which needs USAGE on the schema.', :'qschema')
  , 'HINT gives the GRANT and says why'
);
SELECT throws_ok(
  'DROP OWNED BY extension_drop_test_grantor'
  , '55000'
  , format('PUBLIC lacks USAGE on schema %s, which extension_drop requires', :'qschema')
  , 'DROP OWNED reports the missing USAGE'
);
SELECT lives_ok(
  format('GRANT USAGE ON SCHEMA %I TO PUBLIC', :'extension_drop_schema')
  , 'The GRANT in the HINT recovers'
);

/*
 * Install and update. This file's transaction is rolled back, so extension_drop can be dropped and
 * reinstalled elsewhere regardless of how the suite installed it. CASCADE: existing mode plants a
 * dependent guard object, whose drop notice is hidden to keep the output mode-independent.
 */
SET LOCAL client_min_messages = warning;
SELECT lives_ok(
  'DROP EXTENSION extension_drop CASCADE'
  , 'Drop extension_drop'
);

CREATE SCHEMA "xd no usage";
SELECT throws_ok(
  'CREATE EXTENSION extension_drop SCHEMA "xd no usage"'
  , '55000'
  , 'extension_drop requires PUBLIC to have USAGE on schema "xd no usage"'
  , 'Install into a schema without PUBLIC USAGE fails'
);
SELECT lives_ok(
  $q$DO $d$
  DECLARE h text;
  BEGIN
    CREATE EXTENSION extension_drop SCHEMA "xd no usage";
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.hint', h, false);
  END $d$$q$
  , 'Capture HINT'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , 'Run GRANT USAGE ON SCHEMA "xd no usage" TO PUBLIC (creating the schema first if needed), then retry.'
  , 'HINT gives the exact GRANT'
);

-- The 0.1.1 install script predates the requirement; the update must enforce it, and cope with any schema name
CREATE SCHEMA "x$body$y";
/*
 * The frozen 0.1.1 script forces its own client_min_messages and calls a deprecated cat_tools function;
 * terse verbosity drops the server-version-dependent LOCATION line from that warning.
 */
\set VERBOSITY terse
CREATE EXTENSION extension_drop VERSION '0.1.1' SCHEMA "x$body$y";
\set VERBOSITY verbose
SELECT throws_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , '55000'
  , 'extension_drop requires PUBLIC to have USAGE on schema "x$body$y"'
  , 'Update of an install without PUBLIC USAGE fails'
);
SELECT lives_ok(
  $q$DO $d$
  DECLARE h text;
  BEGIN
    ALTER EXTENSION extension_drop UPDATE;
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    GET STACKED DIAGNOSTICS h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.hint', h, false);
  END $d$$q$
  , 'Capture HINT'
);
SELECT is(
  current_setting('extension_drop_test.hint')
  , 'Run GRANT USAGE ON SCHEMA "x$body$y" TO PUBLIC (creating the schema first if needed), then retry.'
  , 'HINT gives the exact GRANT'
);
GRANT USAGE ON SCHEMA "x$body$y" TO PUBLIC;
SELECT lives_ok(
  'ALTER EXTENSION extension_drop UPDATE'
  , 'Update succeeds once PUBLIC has USAGE, in a schema named x$body$y'
);
SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'extension_drop')
  , (SELECT default_version FROM pg_available_extensions WHERE name = 'extension_drop')
  , 'Updated to the current version'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
