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
  + 2 -- Test __remove and add
  + 1 -- Drop fails
  + 2 -- __remove and drop succeeds

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

\i test/helpers/test_ext__insert.sql

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create test extension'
);

SELECT bag_eq(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
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

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
