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

# extension_drop.sql calls cat_tools.routine__parse_arg_types_text(), which only
# exists starting at cat_tools 0.3.0. PGXN's published cat_tools listing is
# stuck at 0.2.1 from 2017 (the old decibel/cat_tools distribution) and was
# never updated for the Postgres-Extensions/cat_tools fork; `pgxn install
# cat_tools` therefore installs an ancient 0.2.1 lacking the function we need
# (and carrying a pre-omit_column-fix catalog query that breaks on PG12+).
# 0.3.0 itself has not been tagged/published to PGXN yet -- only 0.2.2/0.2.3
# are there, and even 0.2.3 predates this function. So PGXN isn't a usable
# install source right now: build straight from GitHub source instead,
# pinned to a specific commit on Postgres-Extensions/cat_tools's master for
# reproducibility. Once 0.3.0 is tagged and published to PGXN, revert this to
# a plain `pgxn install 'cat_tools>=0.3.0' --sudo`.
CAT_TOOLS_GIT_SHA = 1788dc059d49c4ff716d0c7043c43421671de008
CAT_TOOLS_BUILD_DIR = tmp/cat_tools-build

.PHONY: cat_tools
cat_tools: $(DESTDIR)$(datadir)/extension/cat_tools.control
$(DESTDIR)$(datadir)/extension/cat_tools.control:
	rm -rf $(CAT_TOOLS_BUILD_DIR)
	git clone https://github.com/Postgres-Extensions/cat_tools.git $(CAT_TOOLS_BUILD_DIR)
	cd $(CAT_TOOLS_BUILD_DIR) && git checkout $(CAT_TOOLS_GIT_SHA)
	$(MAKE) -C $(CAT_TOOLS_BUILD_DIR) install PG_CONFIG=$(PG_CONFIG) DESTDIR=$(DESTDIR)
	rm -rf $(CAT_TOOLS_BUILD_DIR)
