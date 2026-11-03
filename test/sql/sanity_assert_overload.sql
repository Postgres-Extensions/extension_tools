\set ECHO none
\i test/pgxntool/setup.sql

/*
 * A role with CREATE on extension_drop's schema can plant a zero-argument extension_drop__sanity_assert()
 * next to the real one; every call must pass the argument explicitly or it becomes ambiguous. plpgsql keeps
 * the plan it resolved, so the overload is planted first and each caller below is first run afterwards, in
 * this file's own session: a caller that already ran in the session would hide a missing argument.
 */
SELECT plan(
  2 -- Setup: role, plant the overload
  + 1 -- CREATE EXTENSION of a registering extension (extension_drop__add)
  + 1 -- extension_drop__get
  + 1 -- DROP EXTENSION of a registered extension (event trigger, extension_drop__claim)
  + 3 -- DROP EXTENSION of an unregistered extension (claim with nothing registered)
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SET client_min_messages = ERROR;

SELECT lives_ok(
  format('CREATE ROLE extension_drop_test_plain; GRANT CREATE ON SCHEMA %I TO extension_drop_test_plain', :'extension_drop_schema')
  , 'Create a role with CREATE on extension_drop''s schema'
);
SELECT lives_ok(
  format($q$DO $d$
  BEGIN
    SET LOCAL ROLE extension_drop_test_plain;
    CREATE FUNCTION %1$I.extension_drop__sanity_assert() RETURNS void LANGUAGE sql AS 'SELECT';
    RESET ROLE;
  END $d$$q$, :'extension_drop_schema')
  , 'Plant a zero-argument extension_drop__sanity_assert()'
);

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'CREATE EXTENSION of an extension that registers drop commands'
);
SELECT lives_ok(
  format($$SELECT * FROM %I.extension_drop__get('extension_drop_test')$$, :'extension_drop_schema')
  , 'extension_drop__get'
);
SELECT lives_ok(
  'DROP EXTENSION extension_drop_test'
  , 'DROP EXTENSION runs the event trigger'
);

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create the extension again'
);
SELECT lives_ok(
  format($$SELECT %I.extension_drop__remove('extension_drop_test')$$, :'extension_drop_schema')
  , 'Unregister it'
);
SELECT lives_ok(
  'DROP EXTENSION extension_drop_test'
  , 'DROP EXTENSION of an unregistered extension'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
