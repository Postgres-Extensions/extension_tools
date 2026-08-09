-- Add any test dependency statements here
-- Note: pgTap is loaded by setup.sql

/*
 * test/install/load.sql (fresh/update mode) installs extension_drop into a
 * freshly created, randomly named schema every run -- see its header
 * comment. This file runs in its own SEPARATE psql session per test file
 * (pg_regress spawns a new connection per test file under test/sql/), so it
 * cannot reuse a psql variable set in load.sql's session; it has to
 * rediscover the schema name from the catalog instead.
 *
 * pg_extension.extnamespace is an oid, not a name -- join pg_namespace
 * directly rather than casting through extnamespace::regnamespace: that
 * cast produces regnamespace's quoted TEXT display form (e.g. "My Schema"
 * complete with literal quote characters for a name needing them), and
 * reinterpreting those literal quotes as part of the name is subtly wrong.
 * The direct join always returns the real, unquoted name.
 *
 * This also handles existing mode "for free": whatever schema a real
 * pg_upgrade actually used is found the same way, no special-casing needed.
 *
 * Deliberately NOT added to search_path: doing so would make any
 * accidentally-unqualified self-reference inside extension_drop's own
 * functions resolve correctly too, masking exactly the class of bug this
 * whole random-schema scheme exists to catch. Every test file that calls
 * into extension_drop's own functions qualifies those calls explicitly
 * using :'extension_drop_schema' instead (test/sql/simple.sql,
 * test/sql/dependency_guard.sql) -- test/finish.sql asserts at the end of
 * every file that the schema never ended up on search_path regardless.
 */
SELECT n.nspname AS extension_drop_schema
FROM pg_namespace n
JOIN pg_extension x ON n.oid = x.extnamespace
WHERE x.extname = 'extension_drop'
\gset

\set TT extension_drop_test_table
CREATE TEMP TABLE :TT (i int);

-- vi: expandtab ts=2 sw=2
