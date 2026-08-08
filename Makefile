# Run test/install/load.sql (extension install) COMMITTED, once, before the
# main pgTAP suite, via pgxntool's test/install feature. Set explicitly
# (rather than left to auto-detect) so an accidentally emptied test/install/
# is a hard build error instead of silently falling back to "disabled".
# Must be set before `include pgxntool/base.mk` below -- base.mk reads it
# while parsing.
PGXNTOOL_ENABLE_TEST_INSTALL = yes

# TEST_LOAD_SOURCE selects how test/install/load.sql installs extension_drop:
#   - fresh (default): CREATE EXTENSION extension_drop (current version).
#   - update: CREATE EXTENSION at TEST_UPDATE_FROM, then ALTER EXTENSION
#     UPDATE -- to TEST_UPDATE_TO if set, otherwise to the current version.
#     Running the SAME suite/expected output against the result asserts
#     update behaves identically to a fresh install. NOTE: extension_drop has
#     never had a real second released version (PGXN's only listing is
#     0.1.x from 2017, predating the current SQL entirely -- see HISTORY.asc
#     and RELEASE.md), so TEST_UPDATE_FROM has no safe default; this mode is
#     wired up and structurally ready, but there is nothing real to update
#     FROM yet, and so no CI leg exercises it in this repo today.
#   - existing: the extension is ALREADY installed (a real pg_upgrade, or an
#     ALTER EXTENSION UPDATE done outside the suite). load.sql does not
#     touch it; it only asserts presence + current version. Pair with
#     CONTRIB_TESTDB=<db> and EXTRA_REGRESS_OPTS=--use-existing to point
#     pg_regress at that database instead of a throwaway one.
#
# Propagated to load.sql as a GUC: pg_regress doesn't forward make variables,
# but the psql processes it spawns inherit the environment, so PGOPTIONS
# reaches load.sql. Exported UNCONDITIONALLY so load.sql can read it without
# missing_ok and fail loudly if it didn't propagate, rather than silently
# defaulting to the wrong mode. The mode is also validated here at
# make-parse-time, so a typo like `TEST_LOAD_SOURCE=fresh ` or
# `TEST_LOAD_SOURCE=typo` fails immediately instead of quietly running the
# default.
TEST_LOAD_SOURCE ?= fresh
ifeq ($(filter $(TEST_LOAD_SOURCE),fresh update existing),)
$(error TEST_LOAD_SOURCE must be 'fresh', 'update' or 'existing', got '$(TEST_LOAD_SOURCE)')
endif

# update-mode version range (load.sql only reads these in update mode).
# Empty TEST_UPDATE_TO means "update to the current default_version". There
# is no safe default for TEST_UPDATE_FROM (see above) -- require it
# explicitly rather than pointing it at a version that doesn't exist.
TEST_UPDATE_FROM ?=
TEST_UPDATE_TO ?=
ifeq ($(TEST_LOAD_SOURCE),update)
  ifeq ($(strip $(TEST_UPDATE_FROM)),)
$(error TEST_UPDATE_FROM must be set when TEST_LOAD_SOURCE=update -- extension_drop has no prior released version yet to default it to)
  endif
endif

export PGOPTIONS := $(PGOPTIONS) -c extension_drop.test_load_mode=$(TEST_LOAD_SOURCE) -c extension_drop.test_update_from=$(TEST_UPDATE_FROM) -c extension_drop.test_update_to=$(TEST_UPDATE_TO)

# make test-update == make test TEST_LOAD_SOURCE=update. Must recurse (a
# fresh $(MAKE)) rather than depend on `test`, so the parse-time
# TEST_LOAD_SOURCE conditional above re-evaluates with update set.
.PHONY: test-update
test-update:
	$(MAKE) test TEST_LOAD_SOURCE=update

include pgxntool/base.mk

# Explicit rather than relying on auto-detect (which enables this whenever
# test/build/*.sql exists) so an accidental deletion of test/build/'s
# contents is a hard error instead of the check silently disappearing.
PGXNTOOL_ENABLE_TEST_BUILD = yes

testdeps: test_extension
test_extension: $(DESTDIR)$datadir)/extension/extension_drop_test.control $(wildcard $(TESTDIR)/*)
$(DESTDIR)$datadir)/extension/extension_drop_test.control:
	make -C $(TESTDIR)/extension install
#
# OTHER DEPS
#
.PHONY: deps
deps: cat_tools
install: deps

# CAT_TOOLS_GIT_REF, if set, installs cat_tools from that git ref instead of
# PGXN -- an explicit, opt-in override for a caller (CI) that needs a
# cat_tools newer than what's published on PGXN, without changing the
# default `pgxn install` behavior every other caller of this Makefile gets.
# Empty (the default) means: behave exactly as before, plain `pgxn install`.
#
# CAT_TOOLS_SKIP_INSTALL, if non-empty, skips installing cat_tools at all --
# for a caller (pg_tle-mode CI) where cat_tools is already provided some
# other way (e.g. pg_tle registration) and a filesystem install as a side
# effect would defeat the point of the test.
CAT_TOOLS_GIT_REF ?=
CAT_TOOLS_SKIP_INSTALL ?=
CAT_TOOLS_BUILD_DIR = tmp/cat_tools-build

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	if [ -n "$(CAT_TOOLS_SKIP_INSTALL)" ]; then \
		: ; \
	elif [ -n "$(CAT_TOOLS_GIT_REF)" ]; then \
		rm -rf $(CAT_TOOLS_BUILD_DIR); \
		git clone https://github.com/Postgres-Extensions/cat_tools.git $(CAT_TOOLS_BUILD_DIR); \
		git -C $(CAT_TOOLS_BUILD_DIR) checkout $(CAT_TOOLS_GIT_REF); \
		make -C $(CAT_TOOLS_BUILD_DIR) install PG_CONFIG=$(PG_CONFIG) DESTDIR=$(DESTDIR); \
		rm -rf $(CAT_TOOLS_BUILD_DIR); \
	else \
		pgxn install 'cat_tools>=0.2.1' --sudo; \
	fi

# Style linter (see https://github.com/Postgres-Extensions/linter, vendored
# at .vendor/linter -- lint.mk is the thin local hand-off, see its comment).
# Scoped to the actively-maintained source rather than the default
# `sql/ test/`: sql/extension_drop--1.0.0.sql is a frozen, already-released
# version file (RELEASE.md's "Ongoing development" section -- once a version
# is released, its sql/<ext>--<version>.sql is never hand-edited again), so
# linting it would produce permanent, unfixable findings and make `make
# lint` unusable as a CI gate. Lint the hand-maintained source instead.
LINT_TARGETS = sql/extension_drop.sql test/
include lint.mk
