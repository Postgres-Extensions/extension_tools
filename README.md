# extension_drop

Register SQL that runs when a given extension is dropped, whether by `DROP
EXTENSION`, `DROP SCHEMA ... CASCADE` or `DROP OWNED BY`. The registration is
removed with the extension.

Requires [cat_tools](https://pgxn.org/dist/cat_tools/) >= 0.3.0.

`PUBLIC` must have USAGE on the schema extension_drop is installed in. The
event trigger runs as whichever role drops an extension, and calls
`_extension_drop__dropping()` in that schema. The leading underscore marks
it as internal, not for external callers (the extension has no internal
schema); it is documented under [How it works](#how-it-works).

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

Only the `extension_drop__usage_guard_start` error has the `GRANT` HINT for
recovering; run it.

Granting USAGE to `PUBLIC` also exposes every other object in that schema
that has `PUBLIC` privileges (functions are executable by `PUBLIC` by
default), so be careful about what schema you install it to.

## Functions

None of these are granted to `PUBLIC` except where noted, since
`extension_drop__add`/`extension_drop__update` let the caller register
arbitrary SQL to run later. Grant them to specific roles as needed.

- `extension_drop__add(extension_name name, sql text) RETURNS void`
  Register `sql` to run when `extension_name` is dropped. `sql` runs with
  `search_path = pg_catalog, pg_temp`: schema-qualify everything it uses (see
  [How it works](#how-it-works)).

- `extension_drop__update(extension_name name, sql text) RETURNS void`
  Replace the SQL registered for `extension_name`. The same `search_path`
  rule applies.

- `extension_drop__remove(extension_name name) RETURNS void`
  Remove the SQL registered for `extension_name`.

- `extension_drop__get(extension_name name) RETURNS extension_drop__commands`
  Look up the row (`extension_name`, `sql`) registered for `extension_name`.
  Granted to `PUBLIC` by default.

- `extension_drop__sanity_check(ignore name DEFAULT NULL) RETURNS name[]`
  Returns the names of extensions that have registered drop commands but no
  longer exist. Should always return an empty array; pass an extension name
  via `ignore` to exclude it from the check (useful while dropping that
  extension). Granted to `PUBLIC` by default.

- `extension_drop__sanity_assert(ignore name DEFAULT NULL) RETURNS void`
  Raises an error if `extension_drop__sanity_check()` (called with the same
  `ignore` argument) isn't empty. Granted to `PUBLIC` by default.
  `_extension_drop__dropping` calls it, as its owner, so it runs with the
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
uses**: tables and functions in any schema (including cat_tools and
extension_drop's own functions). extension_drop's schema is whatever it was
installed into, so when registering, look it up and interpolate it with `%s`
(not `%I`: `regnamespace` output is already quoted):

    SELECT extension_drop__add('my_extension',
             format('SELECT %s.extension_drop__get(%L)',
                    extnamespace::regnamespace, 'my_extension'))
      FROM pg_extension WHERE extname = 'extension_drop';

Nothing but `pg_catalog` and `pg_temp` is on the registered SQL's path, so a
role with CREATE on any schema can't plant objects that it resolves.
Registered SQL runs in no particular order when one command drops several
extensions.

Dropping an extension, registered or not, needs no privileges on
`extension_drop__commands`; the trigger gets the registered SQL from
`_extension_drop__dropping()`, which deletes the registration with its owner's
rights. The SQL itself runs as the dropping role, which may need further
privileges. A stale registration still fails the drop with `XD001`.

`_extension_drop__dropping() RETURNS TABLE(extension_name name, sql text)` is
internal; only the event trigger can use it. It deletes the registrations of
the extensions being dropped and returns them, in no particular order, and
errors when called outside a `sql_drop` trigger, so a direct call can't remove
the registration of a live extension. It is `SECURITY DEFINER` (with
`search_path = pg_catalog, pg_temp` and schema-qualified references), runs
`extension_drop__sanity_assert()` as its owner after the delete, and never
executes the SQL. Granted to `PUBLIC`. Its owner is the role that ran
`CREATE EXTENSION` (or the `ALTER EXTENSION ... UPDATE` that first created
it).

## Known issues

Restoring a `pg_dump` of a database that uses extension_drop has two
problems, tracked in
[#56](https://github.com/Postgres-Extensions/extension_tools/issues/56). The
commands below name the schema `xd` and the target database `newdb`; change
them to match (`xd` also appears inside the `grep` and `sed` patterns).
Schema names that need quoting are untested: `pg_restore -l` prints them
unquoted, but the `sed` pattern and the `GRANT` need them quoted.

### Restore into a schema other than `public` fails

**Create the schema and grant `USAGE` to `PUBLIC` before restoring the
rest.** Otherwise `CREATE EXTENSION` fails with `cannot install
extension_drop in schema "xd"`: pg_dump writes the `GRANT` only after all
extensions are created, and `pg_dump -x` never writes it. Installs into
`public` are not affected. Pre-creating the schema and then restoring the whole
dump only works without `-1`, and logs `schema "xd" already exists`.

Use this for `pg_restore`; it leaves out the commands data, so re-register
what is missing afterwards, as
[the next issue](#restore-fails-with-a-duplicate-key-on-extension_drop__commands)
describes:

    pg_restore -l db.dump > all.list
    grep -E '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - xd ' all.list > schema.list
    grep -v -E '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - xd |TABLE DATA xd extension_drop__commands ' \
      all.list > rest.list
    pg_restore -1 -L schema.list -d newdb db.dump
    psql -d newdb -c 'GRANT USAGE ON SCHEMA xd TO PUBLIC'
    pg_restore -1 -L rest.list -d newdb db.dump

The last command also works with `-j 2` in place of `-1`, or with neither.

Use this for a plain SQL dump made without `--inserts`; it also leaves out
the commands data, so re-register afterwards:

    psql -d newdb -c 'CREATE SCHEMA xd; GRANT USAGE ON SCHEMA xd TO PUBLIC'
    sed '/^CREATE SCHEMA xd;$/d' db.sql \
      | awk '/^COPY .*extension_drop__commands/{s=1}
             !s{print}
             s&&/^\\\.$/{s=0}' \
      | psql -1 -v ON_ERROR_STOP=1 -d newdb

### Restore fails with a duplicate key on `extension_drop__commands`

For a schema other than `public`, use the section 1 recipes, which already
leave this data out. The recipes below apply when extension_drop is in
`public`.

**Leave the data of `extension_drop__commands` out of the restore, then
re-register what your extensions' install scripts don't register.** When an
extension registers drop SQL in its install script, `CREATE EXTENSION`
re-registers it during the restore and the dump's `COPY` then inserts the same
row, failing with `duplicate key value violates unique constraint
"extension_drop__commands_pkey"`. The failed `COPY` inserts none of its rows,
so a restore that continues past it (`psql -f`, `pg_restore` without `-1`, with
or without `-j`) also loses registrations made by direct
`extension_drop__add()` calls. A `-1` restore, or `psql -1`, aborts and
restores nothing.

List the registrations in the source database before dumping, to know which
ones to re-register:

    SELECT * FROM xd.extension_drop__commands;

Leave the data out when dumping (the pattern must be schema-qualified; an
unqualified name silently excludes nothing):

    pg_dump -Fc --exclude-table-data='xd.extension_drop__commands' -f db.dump db

Then, for each registration the restored database lacks:

    SELECT xd.extension_drop__add('my_extension', 'SELECT 1');
