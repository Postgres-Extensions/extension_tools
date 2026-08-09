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

`test/install/load.sql` implements this by installing into a freshly
created, randomly named schema (a constant, quote-forcing prefix plus a
random suffix) on every single fresh/update-mode run — not a configurable
switch confined to one leg or one dedicated test file, since a single
dedicated file only proves the property for whatever it happens to
exercise, not for the rest of the suite. `test/deps.sql` rediscovers that
schema per test-file session (it never adds it to `search_path`, and
never assumes a naming convention beyond what it queries from
`pg_extension`/`pg_namespace` directly); `test/finish.sql` asserts at the
end of every test file that the schema was never reachable via
`search_path` regardless.

`https://github.com/Postgres-Extensions/pg_count_nulls/pull/55` is the
reference this was adapted from (not ported wholesale — see that PR, and
`test/install/load.sql`'s own header comment, for the structural
differences that don't transfer between the two extensions).
