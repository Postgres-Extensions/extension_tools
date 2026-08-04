\set ECHO none
/*
 * Committed-once installer for the test suite's one real dependency: the
 * extension_drop extension itself. (No test roles exist for this extension
 * -- see test/deps.sql -- so unlike cat_tools' equivalent load.sql, there is
 * nothing role-related to install here.)
 *
 * pgxntool's test/install feature runs this file COMMITTED, in its own
 * pg_regress session, BEFORE the main pgTAP suite, so the extension persists
 * into every (rolled-back) test/sql/ file instead of each one re-installing
 * it from scratch. test/deps.sql (run per test) no longer creates the
 * extension; it only sets the psql variables the suite references.
 * test/sql/schema.sql is the one exception: proving the schema-targeting
 * pipeline works is its actual job, so it explicitly drops this committed
 * install and recreates its own copies in schemas it chooses -- safely,
 * since that all happens inside its own rolled-back transaction and never
 * escapes that one file.
 *
 * Three modes, selected by the extension_drop.test_load_mode placeholder
 * GUC, which the Makefile's TEST_LOAD_SOURCE block sets via PGOPTIONS
 * (fresh is the default):
 *   - fresh (default): plain CREATE EXTENSION extension_drop (current
 *     version).
 *   - update: CREATE EXTENSION at an older version
 *     (extension_drop.test_update_from) then ALTER EXTENSION UPDATE -- to
 *     extension_drop.test_update_to when that GUC is non-empty, otherwise to
 *     the current default_version. NOTE: extension_drop has never had a
 *     real second released version -- PGXN's only listing (0.1.x, 2017)
 *     predates the current SQL entirely (see HISTORY.asc/RELEASE.md), so
 *     there is no version that could legitimately fill
 *     extension_drop.test_update_from today. This branch is wired up and
 *     structurally correct (the Makefile refuses to select this mode
 *     without TEST_UPDATE_FROM set explicitly), but has nothing real to
 *     update FROM yet, so it exists ready for the day a second version
 *     ships rather than because it's exercised in CI now.
 *   - existing: the extension is ALREADY installed (by a real binary
 *     pg_upgrade, or an ALTER EXTENSION UPDATE performed outside the
 *     suite). This branch must NOT drop/create/update it -- that would
 *     destroy exactly what "existing" mode exists to test. It only asserts
 *     presence + current version.
 *
 * Unlike cat_tools (whose control file pins schema = 'cat_tools' --
 * CREATE EXTENSION always lands in the same place, no choice), extension_drop's
 * control file has no schema= line, so CREATE EXTENSION here lands wherever
 * the ambient search_path resolves when this file runs -- a fresh psql
 * session's default "$user", public, i.e. public in practice. That's a
 * deliberate, useful default: it proves nothing in extension_drop's install
 * script is hardcoded to a specific schema, the same property
 * test/sql/schema.sql proves again explicitly for non-default schemas.
 */
SET client_min_messages = WARNING;

/*
 * The Makefile always exports extension_drop.test_load_mode via PGOPTIONS.
 * Read it WITHOUT missing_ok: if the GUC did not propagate (a break
 * anywhere in make -> PGOPTIONS -> env -> psql), current_setting errors here
 * and the whole install step fails loudly, instead of silently defaulting
 * and running the wrong suite.
 */
SELECT current_setting('extension_drop.test_load_mode') AS extension_drop_test_load_mode
\gset

DO $DO$
BEGIN
  IF current_setting('extension_drop.test_load_mode') NOT IN ('fresh', 'update', 'existing') THEN
    RAISE EXCEPTION
      'extension_drop.test_load_mode must be ''fresh'', ''update'' or ''existing'', got ''%'''
      , current_setting('extension_drop.test_load_mode')
    ;
  END IF;
END
$DO$;

SELECT
    :'extension_drop_test_load_mode' = 'update'   AS extension_drop_mode_update
  , :'extension_drop_test_load_mode' = 'existing' AS extension_drop_mode_existing
\gset

\if :extension_drop_mode_existing
/*
 * existing mode: do NOT touch the extension. Assert it is installed and at
 * the current default_version -- the pg_upgrade / external update the
 * database just went through is exactly what the suite is validating, so
 * dropping or reinstalling it would defeat the test. Fail loudly on absence
 * or mismatch.
 */
DO $DO$
DECLARE
  v_installed text := (SELECT extversion FROM pg_extension WHERE extname = 'extension_drop');
  v_default   text := (SELECT default_version FROM pg_available_extensions WHERE name = 'extension_drop');
BEGIN
  IF v_installed IS NULL THEN
    RAISE EXCEPTION 'test_load_mode=existing but the extension_drop extension is not installed';
  END IF;
  IF v_installed IS DISTINCT FROM v_default THEN
    RAISE EXCEPTION
      'extension_drop is installed at version % but the current default_version is %'
      , v_installed, v_default
    ;
  END IF;
END
$DO$;
\else
/*
 * fresh / update: (re)install from scratch. Drop-first (CASCADE, matching
 * cat_tools' own load.sql) so a re-run on a persistent cluster installs the
 * newest build instead of reusing stale objects.
 *
 * extension_drop requires cat_tools. CASCADE auto-installs it on PG10+;
 * event triggers exist from 9.3 but CREATE EXTENSION ... CASCADE was only
 * added in PG10, so pre-PG10 needs cat_tools created explicitly first. This
 * mirrors the check test/deps.sql used to do per-test before this file took
 * over installing the extension. server_version_num is read once into a
 * psql variable rather than a runtime DO block, so it can drive \if
 * (client-side) branching around the VERSION-qualified CREATE EXTENSION
 * calls below without needing psql variables interpolated inside a
 * dollar-quoted DO body.
 */
DROP EXTENSION IF EXISTS extension_drop CASCADE;

SELECT current_setting('server_version_num')::int >= 100000 AS extension_drop_pg10_plus
\gset

\if :extension_drop_mode_update
SELECT current_setting('extension_drop.test_update_from') AS extension_drop_test_update_from \gset
SELECT current_setting('extension_drop.test_update_to')   AS extension_drop_test_update_to   \gset
/*
 * Build the optional target clause once so a SINGLE ALTER EXTENSION covers
 * both cases: an empty test_update_to yields '' (update to the current
 * default_version -- the widest path); a non-empty value yields
 * "TO '<v>'". format(%L) quotes the version literal safely.
 */
SELECT CASE WHEN :'extension_drop_test_update_to' = '' THEN ''
            ELSE format('TO %L', :'extension_drop_test_update_to') END
  AS extension_drop_update_to_clause \gset

\if :extension_drop_pg10_plus
CREATE EXTENSION extension_drop VERSION :'extension_drop_test_update_from' CASCADE;
\else
CREATE EXTENSION IF NOT EXISTS cat_tools;
CREATE EXTENSION extension_drop VERSION :'extension_drop_test_update_from';
\endif

/*
 * Suppress the deprecation NOTICEs an update script might emit.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION extension_drop UPDATE :extension_drop_update_to_clause;
SET client_min_messages = WARNING;
\else
\if :extension_drop_pg10_plus
CREATE EXTENSION extension_drop CASCADE;
\else
CREATE EXTENSION IF NOT EXISTS cat_tools;
CREATE EXTENSION extension_drop;
\endif
\endif
-- end \if :extension_drop_mode_update (fresh vs. update install branch)
\endif
-- end \if :extension_drop_mode_existing (existing mode skips the whole (re)install block)

-- vi: expandtab ts=2 sw=2
