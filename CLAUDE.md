# extension_tools (PGXN extension: `extension_drop`)

See [`../ai/CLAUDE.md`](../ai/CLAUDE.md) (or
https://github.com/Postgres-Extensions/ai/blob/main/CLAUDE.md if that path
doesn't exist locally — clone it to `../ai/` per its own first instruction)
and `../ai/PR.md` for cross-repo conventions (CI monitoring, PR/commit
conventions, etc.) not restated here.

## Schema independence in testing

`extension_drop`'s control file has no `schema =` line. In PostgreSQL,
`schema=` (not `relocatable=`) is what pins an extension to one schema at
`CREATE EXTENSION` time — `relocatable` only governs whether it can be moved
again *afterward* via `ALTER EXTENSION ... SET SCHEMA`. An extension can be
"not relocatable" and still fully install-schema-flexible; these are two
independent facts, easy to conflate. Since `extension_drop` omits `schema=`,
it's genuinely schema-flexible: a user can install it into any schema they
choose, and every reference inside its own SQL to its own objects must be
fully schema-qualified — nothing may resolve by accident via `search_path`.

Proving that requires two things together, not either alone:
- At least one tested leg must install into a schema that is verifiably
  ABSENT from `search_path` when the suite's assertions run. Installing into
  two schemas that are both still reachable via `search_path` proves nothing
  — an extension full of unqualified, resolve-by-accident references would
  pass every such leg too, since the accident that makes it work is present
  everywhere it's exercised.
- At least one non-empty leg's schema name should require SQL identifier
  quoting (mixed case, or a space) — an unquoted reference silently folds to
  lowercase and re-tests the same schema twice instead of catching a missing
  quote.

Target the schema with `CREATE EXTENSION ... SCHEMA <name>`, never by
mutating `search_path` before `CREATE EXTENSION` — mutating search_path
first would let the install succeed via a coincidentally-arranged path,
masking exactly the kind of bug this testing exists to catch.

This is best implemented as a `TEST_SCHEMA` switch on the *whole* test
suite (mirroring `TEST_LOAD_SOURCE`'s existing GUC-propagation mechanism
through `test/install/load.sql` / `test/deps.sql`), not confined to a single
dedicated test file — a dedicated file only proves the property for whatever
it happens to exercise, not for the rest of the suite.
`Postgres-Extensions/pg_count_nulls` PR #28 ("TEST_SCHEMA switching in
test/install") is a working reference implementation of this exact pattern.

Full design rationale and gotchas (schema-matrix switch mechanics, the
`schema=`-vs-`relocatable=` distinction, when NOT to build this at all):
see `~/advanced-extension-testing.md` §3a and `~/test-fixes.md` §9
(container-local docs, not part of this repo).
