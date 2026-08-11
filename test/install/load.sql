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
 * it from scratch. test/deps.sql (run per test) only sets the psql
 * variables the suite references; it does not install anything itself.
 *
 * Three modes, selected by the extension_drop.test_load_mode placeholder
 * GUC, which the Makefile's TEST_LOAD_SOURCE block sets via PGOPTIONS
 * (fresh is the default):
 *   - fresh (default): plain CREATE EXTENSION extension_drop (current
 *     version).
 *   - update: CREATE EXTENSION at an older version
 *     (extension_drop.test_update_from) then ALTER EXTENSION UPDATE -- to
 *     extension_drop.test_update_to when that GUC is non-empty, otherwise to
 *     the current default_version. extension_drop.test_update_from defaults
 *     to 0.1.1 (see sql/extension_drop--0.1.1.sql). Exercised in CI as
 *     extra steps in the `test` job's own matrix (see ci.yml).
 *   - existing: the extension is ALREADY installed (by a real binary
 *     pg_upgrade, or an ALTER EXTENSION UPDATE performed outside the
 *     suite). This branch must NOT drop/create/update it -- that would
 *     destroy exactly what "existing" mode exists to test. It only asserts
 *     presence + current version.
 *
 * Unlike cat_tools (whose control file pins schema = 'cat_tools' --
 * CREATE EXTENSION always lands in the same place, no choice), extension_drop's
 * control file has no schema= line, so it is genuinely install-schema-
 * flexible -- nothing in its own SQL may assume where it landed. fresh/update
 * mode exploits that on every single run below: each install targets a
 * freshly created schema with a randomly generated name (never public,
 * never the same name twice in a row), so a hardcoded-schema bug in
 * extension_drop's own SQL fails immediately and unconditionally, instead of
 * only on the rare install that happens to land outside the default
 * search_path. The random schema is targeted directly via CREATE EXTENSION
 * ... SCHEMA, never by first mutating search_path -- that would let an
 * install succeed via a coincidentally arranged search_path and mask
 * exactly the kind of qualification bug this exists to catch. existing mode
 * (below) does not create anything -- it only asserts against whatever a
 * real pg_upgrade already produced, wherever that happened to land.
 * The random schema is deliberately never added to search_path either --
 * see test/deps.sql, which rediscovers it fresh instead of trusting a
 * search_path shortcut, and test/finish.sql, which asserts at the end of
 * every test file that it never ended up on search_path regardless.
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

/*
 * existing mode: do NOT touch the extension. Assert it is installed and at
 * the current default_version -- the pg_upgrade / external update the
 * database just went through is exactly what the suite is validating, so
 * dropping or reinstalling it would defeat the test. Fail loudly on absence
 * or mismatch.
 */
\if :extension_drop_mode_existing
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
/*
 * fresh / update: (re)install from scratch. Drop-first (CASCADE, matching
 * cat_tools' own load.sql) so a re-run on a persistent cluster installs the
 * newest build instead of reusing stale objects.
 *
 * extension_drop requires cat_tools. CASCADE auto-installs it on PG10+;
 * event triggers exist from 9.3 but CREATE EXTENSION ... CASCADE was only
 * added in PG10, so pre-PG10 needs cat_tools created explicitly first.
 * server_version_num is read once into a psql variable rather than a
 * runtime DO block, so it can drive \if
 * (client-side) branching around the VERSION-qualified CREATE EXTENSION
 * calls below without needing psql variables interpolated inside a
 * dollar-quoted DO body.
 */
\else
DROP EXTENSION IF EXISTS extension_drop CASCADE;

SELECT current_setting('server_version_num')::int >= 100000 AS extension_drop_pg10_plus
\gset

/*
 * Fresh/update installs always target a fresh, randomly named schema --
 * never public, never reused -- so nothing below can coast on landing in a
 * predictable place. The constant prefix (including its trailing space)
 * already forces identifier quoting on its own, before the random suffix
 * is even appended -- unlike a mixed-case-only name, which would only force
 * quoting by coincidence of which characters the randomness happened to
 * produce.
 *
 * Cleanup-before-create: a prior run that crashed before reaching its own
 * teardown would otherwise leave its randomly-named schema behind forever,
 * since nothing else knows that name to find and drop it later. Matching on
 * the constant prefix finds and drops any such leftovers before generating
 * this run's own name.
 */
DO $DO$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^extension_drop test schema ' LOOP
    EXECUTE format('DROP SCHEMA %I CASCADE', r.nspname);
  END LOOP;
END
$DO$;

SELECT 'extension_drop test schema ' || substr(md5(random()::text), 1, 12) AS extension_drop_test_schema
\gset

CREATE SCHEMA :"extension_drop_test_schema";

/*
 * CASCADE auto-installs cat_tools on PG10+; pre-PG10 needs it created
 * explicitly first instead (CREATE EXTENSION ... CASCADE was only added in
 * PG10, though event triggers themselves exist from 9.3).
 */
\if :extension_drop_pg10_plus
\else
CREATE EXTENSION IF NOT EXISTS cat_tools;
\endif

-- Read unconditionally; empty and unused outside update mode.
SELECT current_setting('extension_drop.test_update_from') AS extension_drop_test_update_from \gset
SELECT current_setting('extension_drop.test_update_to')   AS extension_drop_test_update_to   \gset

/*
 * One combined suffix covers every fresh/update x pre/post-PG10
 * combination -- SCHEMA is always present, VERSION only in update mode,
 * CASCADE only on PG10+ -- so a SINGLE CREATE EXTENSION statement below
 * handles all four cases instead of duplicating it once per combination.
 */
SELECT
    format(' SCHEMA %I', :'extension_drop_test_schema')
    || CASE WHEN :'extension_drop_mode_update'::boolean
              THEN format(' VERSION %L', :'extension_drop_test_update_from')
              ELSE ''
       END
    || CASE WHEN :'extension_drop_pg10_plus'::boolean THEN ' CASCADE' ELSE '' END
  AS extension_drop_create_suffix
\gset

CREATE EXTENSION extension_drop:extension_drop_create_suffix;

-- update mode only: bring the just-installed old version up to date.
\if :extension_drop_mode_update
/*
 * Build the optional target clause once so a SINGLE ALTER EXTENSION covers
 * both cases: an empty test_update_to yields '' (update to the current
 * default_version -- the widest path); a non-empty value yields
 * "TO '<v>'". format(%L) quotes the version literal safely.
 */
SELECT CASE WHEN :'extension_drop_test_update_to' = '' THEN ''
            ELSE format('TO %L', :'extension_drop_test_update_to') END
  AS extension_drop_update_to_clause \gset

/*
 * Suppress the deprecation NOTICEs an update script might emit.
 */
SET client_min_messages = ERROR;
ALTER EXTENSION extension_drop UPDATE :extension_drop_update_to_clause;
SET client_min_messages = WARNING;
-- end \if :extension_drop_mode_update (update-mode-only ALTER EXTENSION UPDATE)
\endif
-- end \if :extension_drop_mode_existing (existing mode skips the whole (re)install block)
\endif

-- vi: expandtab ts=2 sw=2
