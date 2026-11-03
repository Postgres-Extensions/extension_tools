\set ECHO none
\i test/pgxntool/setup.sql

/*
 * One command dropping several registered extensions runs every registered SQL and removes every
 * registration. A registered SQL that calls extension_drop__claim() again can't claim a surviving
 * extension's registration. With two extensions registered, extension_drop__update() and
 * extension_drop__remove() touch only the named one. Each scenario ends with ROLLBACK TO SAVEPOINT
 * both_registered.
 */
SELECT plan(
  1 -- Setup: table recording which registered SQL ran
  + 2 -- Setup: create extensions
  + 2 -- Setup: register recording SQL
  + 1 -- DROP EXTENSION naming both
  + 1 -- Every registered SQL ran
  + 1 -- Registrations removed
  + 1 -- Setup: first extension's SQL calls extension_drop__claim()
  + 1 -- DROP EXTENSION of the first only
  + 1 -- The nested claim returned nothing
  + 1 -- The surviving registration is intact
  + 2 -- extension_drop__update() changes only the named registration
  + 2 -- extension_drop__remove() removes only the named registration
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT lives_ok(
  'CREATE TEMP TABLE extension_drop_test_ran(name text)'
  , 'Create recording table'
);

SELECT lives_ok('CREATE EXTENSION extension_drop_test_b', 'Create extension_drop_test_b');
SELECT lives_ok('CREATE EXTENSION extension_drop_test', 'Create extension_drop_test');

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update(%L, %L)$$
    , :'extension_drop_schema', n
    , format($s$INSERT INTO pg_temp.extension_drop_test_ran(name) VALUES (%L)$s$, n))
  , 'Register recording SQL for ' || n
)
  FROM unnest(ARRAY['extension_drop_test_b', 'extension_drop_test']) n;

SAVEPOINT both_registered;

SELECT lives_ok(
  'DROP EXTENSION extension_drop_test_b, extension_drop_test'
  , 'Drop both extensions with one command'
);
SELECT bag_eq(
  'SELECT name FROM extension_drop_test_ran'
  , $$VALUES ('extension_drop_test'), ('extension_drop_test_b')$$
  , 'Every registered SQL ran'
);
SELECT is_empty(
  format('SELECT * FROM %I.extension_drop__commands', :'extension_drop_schema')
  , 'Registrations removed'
);
ROLLBACK TO SAVEPOINT both_registered;

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', %L)$$
    , :'extension_drop_schema'
    , format($s$INSERT INTO pg_temp.extension_drop_test_ran(name) SELECT 'nested claim returned ' || count(*) FROM %I.extension_drop__claim()$s$
      , :'extension_drop_schema'))
  , 'Register SQL that calls extension_drop__claim()'
);

SELECT lives_ok('DROP EXTENSION extension_drop_test', 'Drop extension_drop_test only');
SELECT bag_eq(
  'SELECT name FROM extension_drop_test_ran'
  , $$VALUES ('nested claim returned 0')$$
  , 'The nested claim returned no rows'
);
SELECT results_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , $$VALUES ('extension_drop_test_b'::name, 'INSERT INTO pg_temp.extension_drop_test_ran(name) VALUES (''extension_drop_test_b'')'::text)$$
  , 'The surviving extension keeps its registration'
);
ROLLBACK TO SAVEPOINT both_registered;

SELECT lives_ok(
  format($$SELECT %I.extension_drop__update('extension_drop_test', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Update extension_drop_test registration'
);
SELECT bag_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , $$VALUES ('extension_drop_test'::name, 'SELECT 1'::text), ('extension_drop_test_b'::name, 'INSERT INTO pg_temp.extension_drop_test_ran(name) VALUES (''extension_drop_test_b'')'::text)$$
  , 'Update left the other registration unchanged'
);

SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Remove extension_drop_test registration'
);
SELECT results_eq(
  format('SELECT extension_name, sql FROM %I.extension_drop__commands', :'extension_drop_schema')
  , $$VALUES ('extension_drop_test_b'::name, 'INSERT INTO pg_temp.extension_drop_test_ran(name) VALUES (''extension_drop_test_b'')'::text)$$
  , 'Remove left the other registration in place'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
