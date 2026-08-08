\set ECHO none
\set TEST_SCHEMA _Test_Ed
\i test/pgxntool/setup.sql

/*
 * extension_drop is already installed (test/install/load.sql, committed,
 * landing wherever the ambient search_path resolves -- public in practice)
 * before this suite runs. This file's actual job is proving the
 * schema-targeting/quoting pipeline works, so it drops that committed
 * install and recreates its own copies in schemas it chooses instead. Safe
 * to drop here: this whole file runs inside pgTAP's own rolled-back
 * transaction, so load.sql's committed install is back in place for the
 * next test file regardless of what happens below.
 *
 * :TEST_SCHEMA and :TEST_SCHEMA_2 are mixed-case, so every reference to
 * them MUST be identifier-quoted (:"TEST_SCHEMA", or %I via format()) --
 * an unquoted reference would silently fold to lowercase and test a
 * different, unquoted schema instead of this one, without erroring.
 * That's deliberate: it turns a missing-quote bug in the code under test
 * into a hard failure instead of a silent pass.
 */
DROP EXTENSION extension_drop;
CREATE SCHEMA :"TEST_SCHEMA";
CREATE EXTENSION extension_drop SCHEMA :"TEST_SCHEMA";
SET search_path = :"TEST_SCHEMA", tap, "$user";

CREATE SCHEMA "_Test_Ed_2";

SELECT plan(
  0

  + 4 -- create/drop test ext

  + 2 -- has/drop

  + 2 -- create/has

  + 1 -- create test extension in specific schema

  + 2 -- update/verify

  + 1 -- drop old test schema
);

\i test/helpers/test_ext__create_drop.sql

SELECT has_table( :'TEST_SCHEMA', 'extension_drop__commands'::name);
SELECT lives_ok(
  $$DROP EXTENSION extension_drop$$
  , 'Drop extension'
);

\set TEST_SCHEMA_2 _Test_Ed_2
SELECT lives_ok(
  format( $$CREATE EXTENSION extension_drop SCHEMA %I$$, :'TEST_SCHEMA_2' )
  , 'Create extension in schema ' || :'TEST_SCHEMA_2'
);
SELECT has_table( :'TEST_SCHEMA_2', 'extension_drop__commands'::name);

SELECT lives_ok(
  format( $$CREATE EXTENSION extension_drop_test SCHEMA %I$$, :'TEST_SCHEMA_2' )
  , 'Create test extension in ' || :'TEST_SCHEMA_2'
);

-- Ensure test schema 2 isn't in search_path
SET search_path = "$user", public, tap;

SELECT lives_ok(
  format( $$SELECT %I.extension_drop__update('extension_drop_test', 'moo')$$, :'TEST_SCHEMA_2' )
  , 'extension_drop__update()'
);
SELECT bag_eq(
  format( $$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'TEST_SCHEMA_2' )
  , $$SELECT 'extension_drop_test'::name , 'moo'::text$$
  , 'Verify extension_drop__get()'
);

SELECT lives_ok(
  format($$DROP SCHEMA %I$$, :'TEST_SCHEMA')
  , 'Drop schema ' || :'TEST_SCHEMA' || ' without cascade succeeds'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2
