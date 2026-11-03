# extension_tools (PGXN extension: `extension_drop`)

@../ai/CLAUDE.md

If `../ai/CLAUDE.md` doesn't exist locally (see
https://github.com/Postgres-Extensions/ai), clone it now per its own
first instruction, then re-read it — do not rely on the import above
alone to have picked it up in that case.

## Schema independence in testing

`extension_drop`'s control file has no `schema =` line, and its install SQL
never hardcodes a schema for any permanent object — the one
`CREATE SCHEMA __extension_drop` is transient scaffolding, created and
dropped within the same install script, not where anything permanent
lives. Every permanent function sets `search_path = pg_catalog, pg_temp`
(so a role with CREATE on the extension's schema can't hijack operators or
functions) and refers to its own objects through `@extension_schema@`, which
the install and update scripts substitute with the quoted schema name.
Registered SQL runs under the event trigger's own pinned
`pg_catalog, pg_temp`, reset before each registration; the extension's
schema and dependency schemas (e.g. cat_tools) are not on that path, so
registered SQL must qualify everything. The extension itself is genuinely
schema-flexible. See `../ai/CLAUDE.md`'s "Schema-flexibility testing"
section for the general methodology (why `schema=` and not `relocatable=` is what matters, and how
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
`search_path` regardless. It emits one assertion with the same label in
every mode; in existing mode (installed by an external pg_upgrade, placement
not ours to assert) that assertion is `pass()` and checks nothing, so a
single expected output serves all modes.

`https://github.com/Postgres-Extensions/pg_count_nulls/pull/55` is the
reference this was adapted from (not ported wholesale — see that PR, and
`test/install/load.sql`'s own header comment, for the structural
differences that don't transfer between the two extensions).
