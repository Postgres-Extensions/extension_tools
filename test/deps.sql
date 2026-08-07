-- Add any test dependency statements here
-- Note: pgTap is loaded by setup.sql

\set TT extension_drop_test_table
CREATE TEMP TABLE :TT (i int);

-- vi: expandtab ts=2 sw=2
