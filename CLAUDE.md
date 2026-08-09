# extension_tools (PGXN extension: `extension_drop`)

See [`../ai/CLAUDE.md`](../ai/CLAUDE.md) (or
https://github.com/Postgres-Extensions/ai/blob/main/CLAUDE.md if that path
doesn't exist locally — clone it to `../ai/` per its own first instruction)
and `../ai/PR.md` for cross-repo conventions (CI monitoring, PR/commit
conventions, etc.) not restated here.

## Schema independence in testing

`extension_drop`'s control file has no `schema =` line, and its install SQL
never hardcodes a schema for any permanent object — the one
`CREATE SCHEMA __extension_drop` is transient scaffolding, created and
dropped within the same install script, not where anything permanent
lives. Its permanent functions pin their resolution via
`SET search_path FROM CURRENT` at creation time rather than
`@extschema@`-qualifying every reference; either technique gets to the
same schema-independence property. It's genuinely schema-flexible. See
`../ai/CLAUDE.md`'s "Schema-flexibility testing" section for the general
methodology (why `schema=` and not `relocatable=` is what matters, and how
to actually prove search_path-independence).

This is best implemented as a `TEST_SCHEMA` switch on the *whole* test
suite (mirroring `TEST_LOAD_SOURCE`'s existing GUC-propagation mechanism
through `test/install/load.sql` / `test/deps.sql`), not confined to a single
dedicated test file — a dedicated file only proves the property for whatever
it happens to exercise, not for the rest of the suite.
`Postgres-Extensions/pg_count_nulls` PR #28 ("TEST_SCHEMA switching in
test/install") is a working reference implementation of this exact pattern.
