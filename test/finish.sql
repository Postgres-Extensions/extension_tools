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
 */
SELECT is(
  current_schemas(true) @> array[:'extension_drop_schema'::name]
  , false
  , 'extension_drop''s schema should not be reachable via search_path'
);

\i test/pgxntool/finish.sql
