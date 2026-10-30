# extension_drop

Run custom commands when an extension is dropped. By default, `DROP
EXTENSION` simply drops all the objects the extension owns; this lets you
register additional SQL to run when a given extension is dropped.

Requires [cat_tools](https://pgxn.org/dist/cat_tools/) >= 0.3.0.

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
  asserts the table is sane when there are none. `SECURITY DEFINER` (with
  `search_path` pinned to the extension's schema, then `pg_temp`); used by
  the event trigger so dropping an unregistered extension needs no table
  access. Granted to `PUBLIC` by default.

- `extension_drop__sanity_check(ignore name DEFAULT NULL) RETURNS name[]`
  Returns the names of extensions that have registered drop commands but no
  longer exist. Should always return an empty array; pass an extension name
  via `ignore` to exclude it from the check (useful while dropping that
  extension). Granted to `PUBLIC` by default.

- `extension_drop__sanity_assert(ignore name DEFAULT NULL) RETURNS void`
  Raises an error if `extension_drop__sanity_check()` (called with the same
  `ignore` argument) isn't empty. Granted to `PUBLIC` by default.

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

Dropping an unregistered extension needs only USAGE on the extension's
schema (to resolve `extension_drop__registered()`, a `SECURITY DEFINER`
function executable by `PUBLIC`, which the trigger asks which of the dropped
extensions are registered); it needs no privileges on `extension_drop__commands`.
Dropping a registered extension additionally needs SELECT and DELETE on that
table. A role without the access gets an `insufficient_privilege` error that
names the table, its owner and the extensions being dropped, with the
underlying error as DETAIL and a HINT giving the grants that fix it. The
registered SQL runs as the caller and may need further privileges.
