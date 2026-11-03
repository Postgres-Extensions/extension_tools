\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Registered SQL runs when the extension is dropped, by whichever command drops it. Each scenario below the
 * first section ends with a ROLLBACK TO SAVEPOINT; the file's single open transaction makes that possible.
 */
SELECT plan(
  1 -- test/helpers/test_ext__insert.sql
  + 11 -- create, drop (two extensions at once), __remove and __add

  -- Other commands that drop an extension
  + 2 -- setup
  + 1 -- test/helpers/test_ext__insert.sql
  + 3 -- DROP OWNED BY
  + 3 -- test/helpers/test_ext__verify_dropped.sql
  + 4 -- test/helpers/test_ext__create_drop.sql
  + 1 -- test/helpers/test_ext__insert.sql
  + 3 -- DROP SCHEMA CASCADE
  + 3 -- test/helpers/test_ext__verify_dropped.sql
  + 4 -- test/helpers/test_ext__create_drop.sql

  -- Several registered extensions
  + 5 -- setup
  + 3 -- DROP EXTENSION naming both
  + 4 -- nested extension_drop__claim()
  + 4 -- extension_drop__update() and extension_drop__remove()

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

\i test/helpers/test_ext__insert.sql

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create test extension'
);
SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test_b'
  , 'Create second test extension'
);

SELECT bag_eq(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , $$SELECT 'extension_drop_test'::name, 'DELETE FROM pg_temp.extension_drop_test_table'::text$$
  , 'Verify extension_drop__get()'
);

SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test, extension_drop_test_b$$
  , 'Drop both test extensions with one command'
);

SELECT is_empty(
  $$SELECT * FROM $$ || :'TT'
  , :'TT' || ' is empty'
);

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create test extension again'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Drop extension command'
);
SELECT lives_ok(
  format($$SELECT %I.extension_drop__add('extension_drop_test', 'moo')$$, :'extension_drop_schema')
  , 'Add extension command'
);

SELECT throws_ok(
  $$DROP EXTENSION extension_drop_test$$
  , '42601'
  , 'syntax error at or near "moo"'
  , 'Dropping extension with bad command should fail'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Drop extension command'
);
SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test$$
  , 'Drop test extension'
);

/*
 * DROP OWNED BY and DROP SCHEMA CASCADE can drop an extension too; its registered command must run and the
 * registration must go away, or the stale row makes every later DROP EXTENSION fail.
 */
-- Hide the version-specific "drop cascades to" NOTICE
SET client_min_messages = WARNING;

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_owner SUPERUSER'
  , 'Create role'
);
SELECT lives_ok(
  'CREATE SCHEMA extension_drop_test_schema'
  , 'Create schema'
);
SAVEPOINT clean;

\i test/helpers/test_ext__insert.sql
-- ALTER EXTENSION can't change the owner, so create it as that role
SELECT lives_ok(
  $q$DO $$ BEGIN
    SET LOCAL ROLE extension_drop_test_owner;
    CREATE EXTENSION extension_drop_test;
    RESET ROLE;
  END $$$q$
  , 'Create test extension as role'
);
SELECT bag_eq(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , $$SELECT 'extension_drop_test'::name, 'DELETE FROM pg_temp.extension_drop_test_table'::text$$
  , 'Verify extension_drop__get()'
);
SELECT lives_ok(
  'DROP OWNED BY extension_drop_test_owner'
  , 'Drop owned'
);
\i test/helpers/test_ext__verify_dropped.sql
\i test/helpers/test_ext__create_drop.sql
ROLLBACK TO SAVEPOINT clean;

\i test/helpers/test_ext__insert.sql
SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test SCHEMA extension_drop_test_schema'
  , 'Create test extension in schema'
);
SELECT bag_eq(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , $$SELECT 'extension_drop_test'::name, 'DELETE FROM pg_temp.extension_drop_test_table'::text$$
  , 'Verify extension_drop__get()'
);
SELECT lives_ok(
  'DROP SCHEMA extension_drop_test_schema CASCADE'
  , 'Drop schema cascade'
);
\i test/helpers/test_ext__verify_dropped.sql
\i test/helpers/test_ext__create_drop.sql
ROLLBACK TO SAVEPOINT clean;

/*
 * One command dropping several registered extensions runs every registered SQL, each under the event
 * trigger's pinned search_path (an earlier one changing it must not leak into the next), and removes every
 * registration. A registered SQL that calls extension_drop__claim() again can't claim a surviving
 * extension's registration. With two extensions registered, extension_drop__update() and
 * extension_drop__remove() touch only the named one.
 */
SELECT lives_ok(
  'CREATE TEMP TABLE extension_drop_test_ran(name text, path text)'
  , 'Create recording table'
);
SELECT lives_ok('CREATE EXTENSION extension_drop_test_b', 'Create extension_drop_test_b');
SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Create extension_drop_test');

-- Each registered SQL records the path it starts with, then changes it
SELECT lives_ok(
  format($$SELECT %I.extension_drop__update(%L, %L)$$
    , :'extension_drop_schema', n
    , format($s$INSERT INTO pg_temp.extension_drop_test_ran VALUES (%L, current_setting('search_path'));
      SELECT set_config('search_path', 'pg_catalog, public, pg_temp', true)$s$, n))
  , 'Register recording SQL for ' || n
)
  FROM unnest(ARRAY['extension_drop_test_b', 'extension_drop_test']) n;

-- A query returning extension_drop_test_b's registered row, to prove it survives
SELECT format($$SELECT 'extension_drop_test_b'::name, %L::text$$, sql) AS "B_ROW"
  FROM :"extension_drop_schema".extension_drop__commands WHERE extension_name = 'extension_drop_test_b'
\gset

SAVEPOINT both_registered;

SELECT lives_ok(
  'DROP EXTENSION extension_drop_test_b, extension_drop_test'
  , 'Drop both extensions with one command'
);
SELECT bag_eq(
  'SELECT name, path FROM extension_drop_test_ran'
  , $$VALUES ('extension_drop_test', 'pg_catalog, pg_temp'), ('extension_drop_test_b', 'pg_catalog, pg_temp')$$
  , 'Every registered SQL ran, each starting under the pinned search_path'
);
SELECT is_empty(
  format('SELECT * FROM %I.extension_drop__commands', :'extension_drop_schema')
  , 'Registrations removed'
);
ROLLBACK TO SAVEPOINT both_registered;

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', %L)$$
    , :'extension_drop_schema'
    , format($s$INSERT INTO pg_temp.extension_drop_test_ran(name, path)
      SELECT CASE WHEN EXISTS (SELECT 1 FROM %I.extension_drop__claim())
          THEN 'nested claim returned rows' ELSE 'nested claim returned nothing' END
        , current_setting('search_path')$s$
      , :'extension_drop_schema'))
  , 'Register SQL that calls extension_drop__claim()'
);

SELECT lives_ok('DROP EXTENSION extension_drop_test', 'Drop extension_drop_test only');
SELECT bag_eq(
  'SELECT name, path FROM extension_drop_test_ran'
  , $$VALUES ('nested claim returned nothing', 'pg_catalog, pg_temp')$$
  , 'The nested claim returned no rows, under the pinned search_path'
);
SELECT results_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , :'B_ROW'
  , 'The surviving extension keeps its registration'
);
ROLLBACK TO SAVEPOINT both_registered;

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Update extension_drop_test registration'
);
SELECT bag_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , :'B_ROW' || $$ UNION ALL SELECT 'extension_drop_test'::name, 'SELECT 1'::text$$
  , 'Update left the other registration unchanged'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Remove extension_drop_test registration'
);
SELECT results_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , :'B_ROW'
  , 'Remove left the other registration in place'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
