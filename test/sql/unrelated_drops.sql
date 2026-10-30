\set ECHO none
\i test/pgxntool/setup.sql

/*
 * DROP SCHEMA and DROP OWNED fire extension_drop's event trigger, so drops
 * that involve no extension must not depend on the caller's privileges or on
 * the state of extension_drop__commands.
 */
SELECT plan(
  3 -- Non-superuser drops
  + 3 -- Stale registration
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

-- Hide version- and database-specific NOTICE/WARNING text from the drops
SET client_min_messages = ERROR;

SELECT lives_ok(
  'CREATE ROLE extension_drop_test_plain'
  , 'Create non-superuser role'
);

/*
 * Schemas are created as superuser but owned by the role, so it needs no
 * CREATE privilege on the database.
 */
SELECT lives_ok(
  $q$DO $$ BEGIN
    CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain
      CREATE TABLE t(i int);
    SET LOCAL ROLE extension_drop_test_plain;
    DROP SCHEMA extension_drop_test_plain_schema CASCADE;
    RESET ROLE;
  END $$$q$
  , 'Non-superuser DROP SCHEMA CASCADE'
);
SELECT lives_ok(
  $q$DO $$ BEGIN
    CREATE SCHEMA extension_drop_test_plain_schema AUTHORIZATION extension_drop_test_plain
      CREATE TABLE t(i int);
    SET LOCAL ROLE extension_drop_test_plain;
    DROP OWNED BY extension_drop_test_plain;
    RESET ROLE;
  END $$$q$
  , 'Non-superuser DROP OWNED BY'
);

SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert stale registration'
);
SELECT results_eq(
  format($$SELECT %I.extension_drop__sanity_check()$$, :'extension_drop_schema')
  , $$SELECT '{extension_drop_test_stale}'::name[]$$
  , 'Stale registration is present'
);
SELECT lives_ok(
  $$CREATE SCHEMA extension_drop_test_su_schema; DROP SCHEMA extension_drop_test_su_schema$$
  , 'Superuser DROP SCHEMA with stale registration'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
