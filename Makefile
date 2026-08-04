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

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	pgxn install 'cat_tools>=0.2.1' --sudo

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
