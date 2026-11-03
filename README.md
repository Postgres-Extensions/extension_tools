# extension_drop

Register SQL that runs when a given extension is dropped, whether by `DROP
EXTENSION`, `DROP SCHEMA ... CASCADE` or `DROP OWNED BY`. The registration is
removed with the extension.

Requires [cat_tools](https://pgxn.org/dist/cat_tools/) >= 0.3.0.

`PUBLIC` must have USAGE on the schema extension_drop is installed in. The
event trigger runs as whichever role drops an extension, and calls
`extension_drop__claim()` in that schema.

`CREATE EXTENSION` and `ALTER EXTENSION ... UPDATE` fail unless `PUBLIC` has
USAGE. The error's HINT gives the exact `GRANT USAGE ON SCHEMA ... TO PUBLIC`
to run first.

Two event triggers on `REVOKE` and `DROP OWNED` protect it afterwards:

- `extension_drop__usage_guard` (`ddl_command_end`) fails any command that
  would remove USAGE, and the command has no effect.
- `extension_drop__usage_guard_start` (`ddl_command_start`) fails any such
  command while `PUBLIC` already lacks USAGE. That happens if a superuser
  bypassed the triggers, they were disabled or dropped, or the ACL arrived
  through a restore.

Only the second error has the `GRANT` HINT. Run it to recover.

Granting USAGE to `PUBLIC` also exposes every other object in that schema
that has `PUBLIC` privileges (functions are executable by `PUBLIC` by
default), so be careful about what schema you install it to.

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

- `extension_drop__claim() RETURNS TABLE(extension_name name, sql text)`
  Lets any role that can drop an extension do so without privileges on
  `extension_drop__commands`, whether or not the extension is registered. The
  registered SQL runs as the dropping role, so that role needs whatever the SQL
  needs. Only the event trigger can use it: it deletes the registrations of the
  extensions being dropped and returns them, in no particular order, and
  errors when called outside a `sql_drop` trigger, so a direct call can't
  remove the registration of a live extension. It is `SECURITY DEFINER` (with
  `search_path = pg_catalog, pg_temp` and schema-qualified references), runs
  `extension_drop__sanity_assert()` as its owner after the delete, and never
  executes the SQL. Granted to `PUBLIC`. Its owner is the role that ran
  `CREATE EXTENSION` (or the `ALTER EXTENSION ... UPDATE` that first created
  it).

- `extension_drop__sanity_check(ignore name DEFAULT NULL) RETURNS name[]`
  Returns the names of extensions that have registered drop commands but no
  longer exist. Should always return an empty array; pass an extension name
  via `ignore` to exclude it from the check (useful while dropping that
  extension). Granted to `PUBLIC` by default.

- `extension_drop__sanity_assert(ignore name DEFAULT NULL) RETURNS void`
  Raises an error if `extension_drop__sanity_check()` (called with the same
  `ignore` argument) isn't empty. Granted to `PUBLIC` by default.
  `extension_drop__claim` calls it, as its owner, so it runs with the
  owner's rights.

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

Every extension_drop function pins `search_path = pg_catalog, pg_temp`, and
so does the registered SQL: it runs, as the dropping role, under the event
trigger's own pinned path. **Registered SQL must schema-qualify everything it
uses**: its own extension's objects, cat_tools, and extension_drop's
functions. Nothing but `pg_catalog` and `pg_temp` is on its path, so a role
with CREATE on any schema can't plant objects that registered SQL resolves.
Registered SQL runs in no particular order when one command drops several
extensions.

Dropping an extension, registered or not, needs no privileges on
`extension_drop__commands`; the trigger gets the registered SQL from
`extension_drop__claim()`, which deletes the registration with its owner's
rights. The SQL itself runs as the dropping role, which may need further
privileges. A stale registration still fails the drop with `XD001`.
