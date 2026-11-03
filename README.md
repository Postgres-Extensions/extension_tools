# extension_drop

Run custom commands when an extension is dropped. By default, `DROP
EXTENSION` simply drops all the objects the extension owns; this lets you
register additional SQL to run when a given extension is dropped.

Requires [cat_tools](https://pgxn.org/dist/cat_tools/) >= 0.3.0.

`PUBLIC` must have USAGE on the schema extension_drop is installed in:
the event trigger runs as whichever role drops an extension, and resolves
`extension_drop__registered()` in that schema. `CREATE EXTENSION` and
`ALTER EXTENSION ... UPDATE` fail unless it does; the error's HINT gives the
exact `GRANT USAGE ON SCHEMA ... TO PUBLIC` to run first. An event trigger
(`extension_drop_usage_guard`, on `ddl_command_end` for `REVOKE` and `DROP
OWNED`) rejects any later command that would remove it. If PUBLIC loses USAGE
anyway (for example, a superuser bypassed the trigger, the trigger was
disabled or dropped, or the ACL arrived through a restore), every `REVOKE` and
`DROP OWNED` fails with "PUBLIC lacks USAGE on schema ..." until the `GRANT` in its HINT
is run.

Granting USAGE to `PUBLIC` also exposes every other object in that schema
that has `PUBLIC` privileges (functions are executable by `PUBLIC` by
default), so install extension_drop into a schema dedicated to it.

## Functions

None of these are granted to `PUBLIC` except where noted, since
`extension_drop__add`/`extension_drop__update` let the caller register
arbitrary SQL to run later. Grant them to specific roles as needed.

- `extension_drop__add(extension_name name, sql text) RETURNS void`
  Register `sql` to run when `extension_name` is dropped.

- `extension_drop__update(extension_name name, sql text) RETURNS void`
  Replace the SQL registered for `extension_name`.

- `extension_drop__remove(extension_name name) RETURNS void`
  Remove the SQL registered for `extension_name`.

- `extension_drop__get(extension_name name) RETURNS extension_drop__commands`
  Look up the row (`extension_name`, `sql`) registered for `extension_name`.
  Granted to `PUBLIC` by default.

- `extension_drop__registered(extension_names name[]) RETURNS name[]`
  Returns those of `extension_names` that have registered drop commands, and
  asserts the table is sane when there are none. `SECURITY DEFINER`, with
  `search_path = pg_catalog, pg_temp` and schema-qualified references, so a role
  with CREATE on the extension's schema can't make it run their code; used by
  the event trigger so dropping an unregistered extension needs no table
  access. Granted to `PUBLIC`, so any role with USAGE on the schema can ask
  whether a given extension name is registered, and sees the names of stale
  registrations in an `XD001` error (never the registered SQL).

- `extension_drop__sanity_check(ignore name DEFAULT NULL) RETURNS name[]`
  Returns the names of extensions that have registered drop commands but no
  longer exist. Should always return an empty array; pass an extension name
  via `ignore` to exclude it from the check (useful while dropping that
  extension). Granted to `PUBLIC` by default.

- `extension_drop__sanity_assert(ignore name DEFAULT NULL) RETURNS void`
  Raises an error if `extension_drop__sanity_check()` (called with the same
  `ignore` argument) isn't empty. Granted to `PUBLIC` by default.
  `extension_drop__registered` calls it, as its owner, when nothing it was
  asked about is registered.

- `extension_drop__repair() RETURNS void`
  Deletes any stale rows found by `extension_drop__sanity_check()`. This
  should never be needed in normal operation.

## How it works

An event trigger (`extension_drop`, on `sql_drop`) fires whenever an
extension is dropped -- by `DROP EXTENSION`, `DROP SCHEMA ... CASCADE` or
`DROP OWNED BY` -- removes its registration from `extension_drop__commands`
and runs the SQL registered for it via
`extension_drop__add`/`extension_drop__update`. Those commands fire the
trigger for every drop, but it returns immediately unless an extension is
among the dropped objects.

Every extension_drop function pins `search_path = pg_catalog, pg_temp`. The
registered SQL itself runs, as the dropping role, with `search_path =
pg_catalog, <extension_drop's schema>, pg_temp`; schemas of extensions
extension_drop depends on (such as cat_tools) are not on it, so registered
SQL must qualify them. Because that path includes the extension_drop schema,
CREATE on that schema is trusted: a role holding it can plant objects (for
example a `varchar = varchar` operator, which `pg_catalog` has no exact match
for) that registered SQL will resolve. Don't grant it to untrusted roles.

Dropping an unregistered extension needs only USAGE on the extension's
schema (to resolve `extension_drop__registered()`, a `SECURITY DEFINER`
function executable by `PUBLIC`, which the trigger asks which of the dropped
extensions are registered); it needs no privileges on `extension_drop__commands`.
Dropping a registered extension additionally needs SELECT and DELETE on that
table. A role without the access gets an `insufficient_privilege` error that
names the table, its owner and the extensions being dropped, with the
underlying error as DETAIL and a HINT giving the grants that fix it. The
registered SQL runs as the caller and may need further privileges.
