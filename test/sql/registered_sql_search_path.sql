\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Registered SQL runs under the event trigger's own pinned search_path, so it must schema-qualify every name
 * it uses. Each registered statement starts under that path even when an earlier one in the same command
 * changed it.
 */
SELECT plan(
  1 -- Setup: create extension
  + 1 -- Setup: register SQL that records search_path
  + 1 -- DROP EXTENSION
  + 1 -- Registered SQL saw the pinned search_path
  + 2 -- Setup: create both extensions again
  + 2 -- Setup: register path-changing SQL
  + 1 -- DROP EXTENSION naming both
  + 1 -- Each recorded the pinned path
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Create extension_drop_test');
SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', %L)$$
    , :'extension_drop_schema'
    , $s$SELECT set_config('extension_drop_test.registered_path', current_setting('search_path'), false)$s$)
  , 'Register SQL that records search_path'
);
SELECT lives_ok('DROP EXTENSION extension_drop_test', 'DROP EXTENSION runs the registered SQL');
SELECT is(
  current_setting('extension_drop_test.registered_path')
  , 'pg_catalog, pg_temp'
  , 'Registered SQL sees search_path = pg_catalog, pg_temp'
);

-- Each registered SQL records the path it starts with, then changes it
SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Create extension_drop_test again');
SELECT lives_ok('CREATE EXTENSION extension_drop_test_b', 'Create extension_drop_test_b');
CREATE TEMP TABLE extension_drop_test_paths(name text, path text);
SELECT lives_ok(
  format($$SELECT %I.extension_drop__update(%L, %L)$$
    , :'extension_drop_schema', n
    , format($s$INSERT INTO pg_temp.extension_drop_test_paths VALUES (%L, current_setting('search_path'));
      SELECT set_config('search_path', 'pg_catalog, public, pg_temp', true)$s$, n))
  , 'Register path-changing SQL for ' || n
)
  FROM unnest(ARRAY['extension_drop_test', 'extension_drop_test_b']) n;
SELECT lives_ok('DROP EXTENSION extension_drop_test, extension_drop_test_b', 'Drop both extensions with one command');
SELECT bag_eq(
  'SELECT name, path FROM extension_drop_test_paths'
  , $$VALUES ('extension_drop_test', 'pg_catalog, pg_temp'), ('extension_drop_test_b', 'pg_catalog, pg_temp')$$
  , 'Each registered SQL started under the pinned path'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
