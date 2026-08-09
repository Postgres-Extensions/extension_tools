\set ECHO none
\i test/pgxntool/setup.sql

/*
 * Dependency-guard proof. This protects a future "existing" mode CI run
 * (extension_drop already installed by a real pg_upgrade, or an ALTER
 * EXTENSION UPDATE done outside the suite -- see test/install/load.sql and
 * the Makefile's TEST_LOAD_SOURCE machinery): nothing today stops an
 * accidental CASCADE drop, a stray CI step, or a logic bug from silently
 * destroying the real updated/upgraded objects that mode exists to
 * validate -- after which the suite would quietly pass again against a
 * fresh reinstall instead of the thing it was supposed to check.
 *
 * The fix is a view with a HARD pg_depend dependency on a stable
 * extension_drop member: something the extension only ever extends, never
 * drops or redefines. extension_drop__commands is exactly that -- it's the
 * one state table every other object in this extension revolves around
 * (get/add/remove/update, the sanity checks, and the event trigger all key
 * off it); getting rid of it or changing its identity would be a rewrite of
 * the whole extension, not a routine update. Referencing its row type
 * (rather than a specific column) means the guard doesn't need updating
 * even if a future release adds a column to it. extension_drop has no
 * enums (unlike cat_tools' own guard, which types on an enum grown via ADD
 * VALUE) -- a stable table's row type serves the same purpose here.
 *
 * This test PROVES the guard works instead of assuming the SQL is correct:
 * it attempts the actual non-CASCADE DROP EXTENSION and asserts it fails,
 * then asserts both the extension and the guard view are still present
 * afterward. Everything here runs inside pgTAP's own rolled-back
 * transaction, so the guard schema/view never leaks into any other test
 * file.
 *
 * extension_drop__commands is qualified via :'extension_drop_schema'
 * (test/deps.sql) rather than referenced bare -- extension_drop's schema
 * is deliberately NOT on search_path (see test/deps.sql's header), so an
 * unqualified reference here would just fail to find the type, not
 * silently succeed.
 */
CREATE SCHEMA extension_drop_drop_guard;
SELECT format(
  'CREATE VIEW extension_drop_drop_guard.guard AS SELECT NULL::%I.extension_drop__commands AS guarded_member'
  , :'extension_drop_schema'
)
\gexec

SELECT plan(
  0
  + 1 -- non-CASCADE drop is blocked
  + 1 -- extension_drop is still installed
  + 1 -- guard view still present

  + 1 -- extension_drop's schema should not be on search_path (test/finish.sql)
);

/*
 * 2BP01 = dependent_objects_still_exist: the standard error DROP ... RESTRICT
 * (the implicit default for DROP EXTENSION) raises when another object
 * depends on something the extension owns. throws_ok's 3-arg overload is
 * (sql, message, description), not (sql, sqlstate, description) -- passing
 * just the sqlstate there matches message text literally instead of
 * checking the code, so the sqlstate AND the real message both need to be
 * given explicitly (4-arg form) to actually check the error class.
 */
SELECT throws_ok(
  $$DROP EXTENSION extension_drop$$
  , '2BP01'
  , 'cannot drop extension extension_drop because other objects depend on it'
  , 'Non-CASCADE DROP EXTENSION extension_drop is blocked by the dependency guard'
);

SELECT has_extension('extension_drop', 'extension_drop is still installed after the blocked drop attempt');

SELECT has_view('extension_drop_drop_guard', 'guard', 'Dependency guard view is still present after the blocked drop attempt');

\i test/finish.sql

-- vi: expandtab ts=2 sw=2
