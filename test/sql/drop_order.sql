\set ECHO none
\i test/pgxntool/setup.sql

/*
 * (Registrations are set with a direct UPDATE: extension_drop__update() currently updates every row once
 * more than one extension is registered.)
 *
 * One command dropping several registered extensions runs their registered SQL in extension-name order,
 * whatever order the extensions were created in, and removes every registration. A registered SQL that calls
 * extension_drop__claim() again can't claim a surviving extension's registration.
 */
SELECT plan(
  1 -- Setup: table recording the order
  + 2 -- Setup: create extensions, the later name first
  + 2 -- Setup: register recording SQL
  + 1 -- DROP EXTENSION naming both
  + 1 -- Registered SQL ran in name order
  + 1 -- Registrations removed
  + 2 -- Setup: recreate both
  + 1 -- Setup: first extension's SQL calls extension_drop__claim()
  + 1 -- DROP EXTENSION of the first only
  + 1 -- The nested claim returned nothing
  + 1 -- The surviving registration is intact
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT lives_ok(
  'CREATE TEMP TABLE extension_drop_test_order(id serial, name text)'
  , 'Create order table'
);

SELECT lives_ok('CREATE EXTENSION extension_drop_test_b', 'Create extension_drop_test_b');
SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Create extension_drop_test');

SELECT lives_ok(
  format($$UPDATE %I.extension_drop__commands SET sql = %L WHERE extension_name = %L$$
    , :'extension_drop_schema'
    , format($s$INSERT INTO pg_temp.extension_drop_test_order(name) VALUES (%L)$s$, n), n)
  , 'Register recording SQL for ' || n
)
  FROM unnest(ARRAY['extension_drop_test_b', 'extension_drop_test']) n;

SELECT lives_ok(
  'DROP EXTENSION extension_drop_test_b, extension_drop_test'
  , 'Drop both extensions with one command'
);
SELECT is(
  array(SELECT name FROM extension_drop_test_order ORDER BY id)
  , ARRAY['extension_drop_test', 'extension_drop_test_b']
  , 'Registered SQL ran in extension-name order'
);
SELECT is_empty(
  format('SELECT * FROM %I.extension_drop__commands', :'extension_drop_schema')
  , 'Registrations removed'
);

SELECT lives_ok('CREATE EXTENSION extension_drop_test_b', 'Recreate extension_drop_test_b');
SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Recreate extension_drop_test');

SELECT lives_ok(
  format($$UPDATE %I.extension_drop__commands SET sql = %L WHERE extension_name = 'extension_drop_test'$$
    , :'extension_drop_schema'
    , $s$INSERT INTO pg_temp.extension_drop_test_order(name) SELECT 'nested claim returned ' || count(*) FROM extension_drop__claim()$s$)
  , 'Register SQL that calls extension_drop__claim()'
);
TRUNCATE extension_drop_test_order;

SELECT lives_ok('DROP EXTENSION extension_drop_test', 'Drop extension_drop_test only');
SELECT is(
  array(SELECT name FROM extension_drop_test_order ORDER BY id)
  , ARRAY['nested claim returned 0']
  , 'The nested claim returned no rows'
);
SELECT results_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , $$VALUES ('extension_drop_test_b'::name, 'DELETE FROM extension_drop_test_table'::text)$$
  , 'The surviving extension keeps its registration'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
