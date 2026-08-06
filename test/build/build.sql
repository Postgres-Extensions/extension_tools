\set ECHO none
BEGIN;
\i test/pgxntool/psql.sql

CREATE EXTENSION IF NOT EXISTS cat_tools;

/*
 * Suppress NOTICEs from the raw install script itself (e.g. "%TYPE converted
 * to ..." with a version-specific source-file LOCATION line) so this file's
 * expected output stays stable across PostgreSQL minor versions instead of
 * capturing verbose, version-dependent messages.
 */
SET client_min_messages = WARNING;

\echo
\echo INSTALL
\t
\i sql/extension_drop.sql

\echo # TRANSACTION INTENTIONALLY LEFT OPEN
