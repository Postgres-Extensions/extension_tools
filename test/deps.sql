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
 * Added TO search_path (not excluded) so the rest of the suite's existing
 * unqualified calls into extension_drop keep working unchanged.
 * test/sql/schema.sql is the one place that deliberately excludes a schema
 * from search_path, to prove qualified calls work even then.
 */
SELECT n.nspname AS extension_drop_schema
FROM pg_namespace n
JOIN pg_extension x ON n.oid = x.extnamespace
WHERE x.extname = 'extension_drop'
\gset

SET search_path = :"extension_drop_schema", "$user", public, tap;

\set TT extension_drop_test_table
CREATE TEMP TABLE :TT (i int);

-- vi: expandtab ts=2 sw=2
