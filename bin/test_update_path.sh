#!/bin/sh
# Exercises the extension_drop update path: 0.1.1 (the only version of
# extension_drop published to PGXN, its install script matching PGXN's
# originally published 2017 dist archive byte-for-byte -- see
# sql/extension_drop--0.1.1.sql and RELEASE.md/HISTORY.asc) -> stable (this
# repo's current source).
#
# Assumes extension_drop and cat_tools are already built and installed into
# the active PostgreSQL cluster (`make install`, which pulls in the cat_tools
# deps target first) and that psql's ambient connection defaults reach it.
#
# Each step is PROVEN, not assumed: the dependency-guard checks actually
# attempt the blocked DROP EXTENSION and inspect the real error, rather than
# trusting the guard exists; the version check reads extension_drop.control's
# default_version dynamically rather than hardcoding an expected value that
# would silently drift out of sync with a future release.
#   1. CREATE EXTENSION extension_drop VERSION '0.1.1' -- installs the
#      actual historical release. CASCADE (to auto-install cat_tools) only
#      exists from PG10 -- pre-PG10 needs cat_tools created explicitly
#      first, same as test/install/load.sql.
#   2. Plant a dependency-guard view and prove a non-CASCADE DROP EXTENSION
#      is blocked -- BEFORE the update, proving the guard actually attaches
#      to the 0.1.1-era extension_drop__commands table.
#   3. ALTER EXTENSION extension_drop UPDATE -- runs
#      sql/extension_drop--0.1.1--stable.sql.
#   4. Re-prove the SAME guard still blocks a non-CASCADE drop -- proves the
#      update script didn't touch extension_drop__commands's identity.
#   5. Assert the installed version now matches extension_drop.control's
#      default_version, read dynamically from the control file rather than
#      hardcoded, with empty-value guards.
set -eu

cd "$(dirname "$0")/.."

DB=${1:-extension_drop_update_test}

dropdb --if-exists "$DB"
createdb "$DB"

PG10_PLUS=$(psql -tAc "SELECT current_setting('server_version_num')::int >= 100000" -d "$DB")

if [ "$PG10_PLUS" = "t" ]; then
  CREATE_EXTENSION_DROP="CREATE EXTENSION extension_drop VERSION '0.1.1' CASCADE;"
else
  CREATE_EXTENSION_DROP="CREATE EXTENSION IF NOT EXISTS cat_tools;
CREATE EXTENSION extension_drop VERSION '0.1.1';"
fi

psql -v ON_ERROR_STOP=1 -d "$DB" -c "
$CREATE_EXTENSION_DROP

CREATE SCHEMA extension_drop_drop_guard;
CREATE VIEW extension_drop_drop_guard.guard AS
  SELECT NULL::extension_drop__commands AS guarded_member;
"

assert_guard_blocks_drop() {
  label=$1
  if psql -v ON_ERROR_STOP=1 -d "$DB" -c 'DROP EXTENSION extension_drop' >/tmp/guard_drop.out 2>/tmp/guard_drop.err; then
    echo "FAIL ($label): DROP EXTENSION extension_drop succeeded -- the dependency guard did not block it" >&2
    exit 1
  fi
  if ! grep -q 'cannot drop extension extension_drop because other objects depend on it' /tmp/guard_drop.err; then
    echo "FAIL ($label): DROP EXTENSION failed, but not with the expected dependency-guard error:" >&2
    cat /tmp/guard_drop.err >&2
    exit 1
  fi
  echo "OK ($label): non-CASCADE DROP EXTENSION extension_drop is blocked by the dependency guard"
}

assert_guard_blocks_drop "pre-update, at 0.1.1"

psql -v ON_ERROR_STOP=1 -d "$DB" -c "SET client_min_messages = ERROR; ALTER EXTENSION extension_drop UPDATE"

assert_guard_blocks_drop "post-update"

INSTALLED=$(psql -tAc "SELECT extversion FROM pg_extension WHERE extname = 'extension_drop'" -d "$DB" | tr -d '[:space:]')
EXPECTED=$(sed -n "s/^default_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" extension_drop.control | tr -d '[:space:]')

if [ -z "$INSTALLED" ] || [ -z "$EXPECTED" ] || [ "$INSTALLED" != "$EXPECTED" ]; then
  echo "FAIL: installed='$INSTALLED' expected='$EXPECTED' (derived from extension_drop.control)" >&2
  exit 1
fi
echo "OK: extension_drop landed at '$INSTALLED' after update, matching extension_drop.control's default_version"

dropdb "$DB"

echo "PASS: 0.1.1 -> $INSTALLED update path verified (install, guard survival, version assertion)."

# vi: expandtab ts=2 sw=2
