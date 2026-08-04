\set ECHO none
\i test/pgxntool/setup.sql

SELECT plan(
  0
  
  + 1 -- Insert into test table

  + 1 -- Create test extension
  + 1 -- Verify test extension drop command
  + 1 -- Drop test extension
  + 1 -- Verify test table is empty

  + 1 -- Create test extension again
  -- Change search path
  + 2 -- Test __remove and add
  + 1 -- Drop fails
  + 2 -- __remove and drop succeeds
);

\i test/helpers/test_ext__insert.sql

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create test extension'
);

SELECT bag_eq(
  $$SELECT * FROM extension_drop__get('extension_drop_test')$$
  , $$SELECT 'extension_drop_test'::name, 'DELETE FROM extension_drop_test_table'::text$$
  , 'Verify extension_drop__get()'
);

SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test$$
  , 'Drop test extension'
);

SELECT is_empty(
  $$SELECT * FROM $$ || :'TT'
  , :'TT' || ' is empty'
);

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create test extension again'
);

/*
 * These calls used to be schema-qualified (_test_ed.extension_drop__remove
 * etc.) back when this file's own per-test deps.sql install put
 * extension_drop in a private schema and then this section intentionally
 * moved search_path away from it, to prove a qualified call still worked.
 * extension_drop is now installed once, ambiently (in public, see
 * test/install/load.sql), by the time this file runs -- 'public' is always
 * on search_path regardless of the change below, so there's no longer a
 * schema this file controls to qualify against here. Proving
 * schema-qualified access explicitly is test/sql/schema.sql's job now.
 */
SET search_path = "$user", public, tap;

SELECT lives_ok(
  $$SELECT extension_drop__remove('extension_drop_test')$$
  , 'Drop extension command'
);
SELECT lives_ok(
  $$SELECT extension_drop__add('extension_drop_test', 'moo')$$
  , 'Add extension command'
);

SELECT throws_ok(
  $$DROP EXTENSION extension_drop_test$$
  , '42601'
  , 'syntax error at or near "moo"'
  , 'Dropping extension with bad command should fail'
);

SELECT lives_ok(
  $$SELECT extension_drop__remove('extension_drop_test')$$
  , 'Drop extension command'
);
SELECT lives_ok(
  $$DROP EXTENSION extension_drop_test$$
  , 'Drop test extension'
);

\i test/pgxntool/finish.sql

-- vi: expandtab sw=2 ts=2
