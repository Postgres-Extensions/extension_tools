/*
 * Sanity check: prove nothing in this test file left extension_drop's
 * schema reachable via search_path by the time it finishes, regardless of
 * what the file itself was testing. This repo's test files are individual
 * plain pgTAP scripts (no shared runtests()/teardown__ function library to
 * hook a check into, unlike e.g. Postgres-Extensions/pg_count_nulls) -- so
 * every file under test/sql that needs this calls this file instead of
 * calling test/pgxntool/finish.sql (the vendored default) directly. This
 * file does the check, then delegates to the real one.
 *
 * Reuses :'extension_drop_schema' (set once by test/deps.sql) rather than
 * rediscovering it -- no test file moves extension_drop to a different
 * schema mid-run, so the value set at the top of the session is still
 * accurate here.
 *
 * existing mode is the one exception: there, extension_drop was installed
 * by a real pg_upgrade external to this suite (see test/install/load.sql),
 * landing wherever THAT process's own ambient defaults put it -- typically
 * public, which stays on search_path by default. We have no control over
 * or guarantee about that placement, so there's nothing to assert here in
 * that mode; skip() still counts as one test, so no plan() changes needed
 * either way.
 */
SELECT current_setting('extension_drop.test_load_mode') = 'existing' AS extension_drop_existing_mode
\gset

\if :extension_drop_existing_mode
SELECT skip('existing mode: extension_drop''s placement is outside this suite''s control');
\else
SELECT is(
  current_schemas(true) @> array[:'extension_drop_schema'::name]
  , false
  , 'extension_drop''s schema should not be reachable via search_path'
);
\endif

\i test/pgxntool/finish.sql
