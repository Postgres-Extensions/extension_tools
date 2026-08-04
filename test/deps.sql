-- Add any test dependency statements here
-- Note: pgTap is loaded by setup.sql

/*
 * extension_drop itself used to be (re)installed here, per test file. It's
 * now installed ONCE, COMMITTED, by test/install/load.sql (pgxntool's
 * test/install feature) before this suite runs at all -- this file no
 * longer touches it. test/sql/schema.sql is the one test that actually
 * drops/recreates the extension itself (that's what it's testing); every
 * other test file just uses the extension load.sql already installed.
 */

\set TT extension_drop_test_table
CREATE TEMP TABLE :TT (i int);

-- vi: expandtab ts=2 sw=2
