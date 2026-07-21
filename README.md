# extension_drop

Run custom commands when an extension is dropped. By default, `DROP
EXTENSION` simply drops all the objects the extension owns; this lets you
register additional SQL to run when a given extension is dropped.

Requires [cat_tools](https://pgxn.org/dist/cat_tools/) >= 0.2.1.

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
extension is dropped, runs any SQL registered for it via
`extension_drop__add`/`extension_drop__update`, and removes the registration
afterward.
