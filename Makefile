include pgxntool/base.mk

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
