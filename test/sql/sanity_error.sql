\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Every path that raises XD001 gets its message, DETAIL and HINT from extension_drop__sanity_error().
 */
SELECT plan(
  1 -- Setup: stale registration
  + 1 -- Capture from extension_drop__sanity_assert
  + 1 -- Capture from extension_drop__registered
  + 3 -- sanity_assert text
  + 3 -- registered text matches sanity_assert
  + 1 -- extension_drop__sanity_error returns the same text
  + 1 -- Several extensions: plural wording
  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

SELECT lives_ok(
  format($$INSERT INTO %I.extension_drop__commands VALUES('extension_drop_test_stale', 'SELECT 1')$$, :'extension_drop_schema')
  , 'Insert a stale registration'
);

-- Both paths raise from the shared function; stash each one's text in GUCs to compare
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
  format($q$DO $d$
  DECLARE m text; d text; h text;
  BEGIN
    PERFORM %I.extension_drop__registered('{extension_drop_test_other}');
  EXCEPTION WHEN sqlstate 'XD001' THEN
    GET STACKED DIAGNOSTICS m = MESSAGE_TEXT, d = PG_EXCEPTION_DETAIL, h = PG_EXCEPTION_HINT;
    PERFORM set_config('extension_drop_test.registered_msg', m, false), set_config('extension_drop_test.registered_detail', d, false)
      , set_config('extension_drop_test.registered_hint', h, false);
  END $d$$q$, :'extension_drop_schema')
  , 'Capture the error from extension_drop__registered'
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

SELECT is(current_setting('extension_drop_test.registered_msg'), current_setting('extension_drop_test.assert_msg'), 'registered message');
SELECT is(current_setting('extension_drop_test.registered_detail'), current_setting('extension_drop_test.assert_detail'), 'registered DETAIL');
SELECT is(current_setting('extension_drop_test.registered_hint'), current_setting('extension_drop_test.assert_hint'), 'registered HINT');

SELECT results_eq(
  format($$SELECT message, detail, hint FROM %I.extension_drop__sanity_error('{extension_drop_test_stale}')$$, :'extension_drop_schema')
  , format(
      $$VALUES (%L, %L, %L)$$
      , current_setting('extension_drop_test.assert_msg')
      , current_setting('extension_drop_test.assert_detail')
      , current_setting('extension_drop_test.assert_hint')
    )
  , 'extension_drop__sanity_error returns the text both paths raised'
);

SELECT results_eq(
  format($$SELECT detail FROM %I.extension_drop__sanity_error('{extension_drop_test_a,extension_drop_test_b}')$$, :'extension_drop_schema')
  , $$VALUES ('These extensions do not exist: extension_drop_test_a, extension_drop_test_b')$$
  , 'Plural wording'
);

\i test/finish.sql

-- vi: expandtab sw=2 ts=2
