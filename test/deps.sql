-- IF NOT EXISTS will emit NOTICEs, which is annoying
SET client_min_messages = WARNING;

-- Add any test dependency statements here
-- Note: pgTap is loaded by setup.sql

-- Re-enable notices
SET client_min_messages = NOTICE;

\set TT extension_drop_test_table
CREATE TEMP TABLE :TT (i int);

/*
 * :TEST_SCHEMA can be mixed-case (see test/sql/schema.sql), so it MUST be
 * identifier-quoted here -- an unquoted interpolation would silently fold
 * to lowercase and every test would end up running against a different,
 * unquoted schema than the one it thinks it's using.
 */
CREATE SCHEMA :"TEST_SCHEMA";
SET search_path = :"TEST_SCHEMA", tap, "$user";

/*
 * Now load our extension. We don't use IF NOT EXISTs here because we want an
 * error if the extension is already loaded (because we want to ensure we're
 * getting the very latest version).
 */
SET client_min_messages = WARNING; -- Squelch notice from CASCADE
DO $$ BEGIN
  IF current_setting('server_version_num')::int < 100000 THEN
    CREATE EXTENSION IF NOT EXISTS cat_tools;
    CREATE EXTENSION extension_drop ;
  ELSE
    EXECUTE $exec$CREATE EXTENSION extension_drop CASCADE$exec$;
  END IF;
END$$;
SET client_min_messages = NOTICE;

-- vi: expandtab ts=2 sw=2
