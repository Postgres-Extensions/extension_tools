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
 * Discovers extension_drop's schema fresh, the same way test/deps.sql does,
 * rather than trusting a psql variable that might be stale by now --
 * test/sql/schema.sql deliberately drops/recreates extension_drop in
 * schemas of its own choosing, so "wherever it actually is at this exact
 * moment" is the only thing that matters for this check.
 */
SELECT n.nspname AS extension_drop_finish_schema
FROM pg_namespace n
JOIN pg_extension x ON n.oid = x.extnamespace
WHERE x.extname = 'extension_drop'
\gset

SELECT is(
  current_schemas(true) @> array[:'extension_drop_finish_schema'::name]
  , false
  , 'extension_drop''s schema should not be reachable via search_path'
);

\i test/pgxntool/finish.sql
