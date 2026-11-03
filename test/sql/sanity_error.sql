\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Every path that raises XD001 gets the same message, DETAIL and HINT.
 */
SELECT plan(
  1 -- Setup: registered extension
  + 1 -- Setup: stale registration
  + 1 -- Capture from extension_drop__sanity_assert
  + 1 -- Capture from the event trigger (DROP EXTENSION)
  + 3 -- sanity_assert text
  + 3 -- event trigger text matches sanity_assert
  + 5 -- Several extensions: plural wording
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT lives_ok(
  'CREATE EXTENSION extension_drop_test'
  , 'Create a registered extension'
);
SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert a stale registration'
);

-- Both paths raise from the shared function (the trigger via extension_drop__claim); stash each one's text in GUCs to compare
SELECT lives_ok(
  format($q$DO $d$
  DECLARE m text; d text; h text;
  BEGIN
    PERFORM %I.extension_drop__sanity_assert();
  EXCEPTION WHEN sqlstate 'XD001' THEN
    GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.assert_msg', m, false), set_config('extension_drop_test.assert_detail', d, false)
      , set_config('extension_drop_test.assert_hint', h, false);
  END $d$$q$, :'extension_drop_schema')
  , 'Capture the error from extension_drop__sanity_assert'
);
SELECT lives_ok(
  $q$DO $d$
  DECLARE m text; d text; h text;
  BEGIN
    DROP EXTENSION extension_drop_test;
  EXCEPTION WHEN sqlstate 'XD001' THEN
    GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.registered_msg', m, false), set_config('extension_drop_test.registered_detail', d, false)
      , set_config('extension_drop_test.registered_hint', h, false);
  END $d$$q$
  , 'Capture the error from the event trigger'
);

SELECT is(current_setting('extension_drop_test.assert_msg'), 'unexpected drop commands', 'sanity_assert message');
SELECT is(
  current_setting('extension_drop_test.assert_detail')
  , 'This extension does not exist: extension_drop_test_stale'
  , 'sanity_assert DETAIL'
);
SELECT is(
  current_setting('extension_drop_test.assert_hint')
  , E'This should not happen unless someone manually inserted into "extension_drop__commands" or messed with the "extension_drop" event trigger.\n  Use SELECT extension_drop__repair() to fix this.'
  , 'sanity_assert HINT'
);

SELECT is(current_setting('extension_drop_test.registered_msg'), current_setting('extension_drop_test.assert_msg'), 'event trigger message');
SELECT is(current_setting('extension_drop_test.registered_detail'), current_setting('extension_drop_test.assert_detail'), 'event trigger DETAIL');
SELECT is(current_setting('extension_drop_test.registered_hint'), current_setting('extension_drop_test.assert_hint'), 'event trigger HINT');

SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale2', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert a second stale registration'
);
SELECT lives_ok(
  format($q$DO $d$
  DECLARE d text;
  BEGIN
    PERFORM %I.extension_drop__sanity_assert();
  EXCEPTION WHEN sqlstate 'XD001' THEN
    GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
    PERFORM set_config('extension_drop_test.plural_detail', d, false);
  END $d$$q$, :'extension_drop_schema')
  , 'Capture the error with two stale registrations'
);
-- Names come out in no particular order
SELECT matches(
  current_setting('extension_drop_test.plural_detail')
  , '^These extensions do not exist: '
  , 'Plural wording'
);
SELECT matches(
  current_setting('extension_drop_test.plural_detail')
  , '\mextension_drop_test_stale\M'
  , 'Plural DETAIL names the first stale extension'
);
SELECT matches(
  current_setting('extension_drop_test.plural_detail')
  , '\mextension_drop_test_stale2\M'
  , 'Plural DETAIL names the second stale extension'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
