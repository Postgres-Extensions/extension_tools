\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Registered SQL runs under the event trigger's own pinned search_path, so it must schema-qualify every name
 * it uses.
 */
SELECT plan(
  1 -- Setup: create extension
  + 1 -- Setup: register SQL that records search_path
  + 1 -- DROP EXTENSION
  + 1 -- Registered SQL saw the pinned search_path
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

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
