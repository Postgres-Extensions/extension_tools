PGXNTOOL_DIR := pgxntool

# Ensure 'all' is the default target (not META.json which happens to be first)
.DEFAULT_GOAL := all

#
# META.json
#
PGXNTOOL_distclean += META.json
META.json: META.in.json $(PGXNTOOL_DIR)/build_meta.sh
	@$(PGXNTOOL_DIR)/build_meta.sh $< $@

#
# meta.mk
#
# Build meta.mk, which contains PGXN distribution info from META.json
PGXNTOOL_distclean += meta.mk
meta.mk: META.json Makefile $(PGXNTOOL_DIR)/base.mk $(PGXNTOOL_DIR)/meta.mk.sh
	@$(PGXNTOOL_DIR)/meta.mk.sh $< >$@

-include meta.mk

#
# control.mk
#
# Build control.mk, which contains extension info from .control files
# This is separate from meta.mk because:
#   - META.json specifies PGXN distribution metadata
#   - .control files specify what PostgreSQL actually uses (e.g., default_version)
# These can differ, and PostgreSQL cares about the control file version.
#
# Find all control files first (needed for dependencies)
PGXNTOOL_CONTROL_FILES := $(wildcard *.control)
PGXNTOOL_distclean += control.mk
control.mk: $(PGXNTOOL_CONTROL_FILES) Makefile $(PGXNTOOL_DIR)/base.mk $(PGXNTOOL_DIR)/control.mk.sh
	@$(PGXNTOOL_DIR)/control.mk.sh $(PGXNTOOL_CONTROL_FILES) >$@

-include control.mk

DATA         = $(EXTENSION_VERSION_FILES) $(wildcard sql/*--*--*.sql)
DOC_DIRS	+= doc
# NOTE: if this is empty it gets forcibly defined to NUL before including PGXS
DOCS		+= $(foreach dir,$(DOC_DIRS),$(wildcard $(dir)/*))

# Find all asciidoc targets
ASCIIDOC ?= $(shell which asciidoctor 2>/dev/null || which asciidoc 2>/dev/null)
ASCIIDOC_EXTS	+= adoc asciidoc
ASCIIDOC_FILES	+= $(foreach dir,$(DOC_DIRS),$(foreach ext,$(ASCIIDOC_EXTS),$(wildcard $(dir)/*.$(ext))))

PG_CONFIG   ?= pg_config
TESTDIR		?= test
TESTOUT		?= $(TESTDIR)
# .source files are OPTIONAL - see "pg_regress workflow" comment below for details
TEST__SOURCE__INPUT_FILES	+= $(wildcard $(TESTDIR)/input/*.source)
TEST__SOURCE__OUTPUT_FILES	+= $(wildcard $(TESTDIR)/output/*.source)
TEST__SOURCE__INPUT_AS_OUTPUT		 = $(subst input,output,$(TEST__SOURCE__INPUT_FILES))
TEST_SQL_FILES		+= $(wildcard $(TESTDIR)/sql/*.sql)
TEST_RESULT_FILES	 = $(patsubst $(TESTDIR)/sql/%.sql,$(TESTDIR)/expected/%.out,$(TEST_SQL_FILES))
TEST_FILES	 = $(TEST__SOURCE__INPUT_FILES) $(TEST_SQL_FILES)
# Ephemeral files generated from source files (should be cleaned)
# input/*.source → sql/*.sql (converted by pg_regress)
TEST__SOURCE__SQL_FILES	 = $(patsubst $(TESTDIR)/input/%.source,$(TESTDIR)/sql/%.sql,$(TEST__SOURCE__INPUT_FILES))
# output/*.source → expected/*.out (converted by pg_regress)
TEST__SOURCE__EXPECTED_FILES = $(patsubst $(TESTDIR)/output/%.source,$(TESTDIR)/expected/%.out,$(TEST__SOURCE__OUTPUT_FILES))
REGRESS		 = $(sort $(notdir $(subst .source,,$(TEST_FILES:.sql=)))) # Sort is to get unique list
REGRESS_OPTS = --inputdir=$(TESTDIR) --outputdir=$(TESTOUT) # See additional setup below

# Generate unique database name for tests to prevent conflicts across projects
# Uses project name + first 5 chars of md5 hash of current directory
# This prevents multiple test runs in different directories from clobbering each other
REGRESS_DBHASH := $(shell echo $(CURDIR) | (md5 2>/dev/null || md5sum) | cut -c1-5)
REGRESS_DBNAME := $(or $(PGXN),regression)_$(REGRESS_DBHASH)
REGRESS_OPTS += --dbname=$(REGRESS_DBNAME)
MODULES      = $(patsubst %.c,%,$(wildcard src/*.c))
ifeq ($(strip $(MODULES)),)
MODULES =# Set to NUL so PGXS doesn't puke
endif

EXTRA_CLEAN  = $(wildcard ../$(PGXN)-*.zip) $(TEST__SOURCE__SQL_FILES) $(TEST__SOURCE__EXPECTED_FILES) pg_tle/

# Get Postgres version, as well as major (9.4, etc) version.
# NOTE! In at least some versions, PGXS defines VERSION, so we intentionally don't use that variable
PGVERSION 	 = $(shell $(PG_CONFIG) --version | awk '{sub("(alpha|beta|devel).*", ""); print $$2}')
# Multiply by 10 is easiest way to handle version 10+
MAJORVER 	 = $(shell echo $(PGVERSION) | awk -F'.' '{if ($$1 >= 10) print $$1 * 10; else print $$1 * 10 + $$2}')

# Function for testing a condition
test		 = $(shell test $(1) $(2) $(3) && echo yes || echo no)

GE91		 = $(call test, $(MAJORVER), -ge, 91)

ifeq ($(GE91),yes)
all: $(EXTENSION_VERSION_FILES)
endif

ifeq ($($call test, $(MAJORVER), -lt 13), yes)
	REGRESS_OPTS += --load-language=plpgsql
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
# Need to do this because we're not setting EXTENSION
MODULEDIR = extension
DATA += $(wildcard *.control)

# Don't have installcheck bomb on error
.IGNORE: installcheck
installcheck: $(TEST_RESULT_FILES) $(TEST_SQL_FILES) $(TEST__SOURCE__INPUT_FILES) | $(TESTDIR)/sql/ $(TESTDIR)/expected/ $(TESTOUT)/results/

#
# TEST SUPPORT
#
# These targets are meant to make running tests easier.

# make test: run any test dependencies, then do a `make install installcheck`.
# If regressions are found, it will output them.
#
# This used to depend on clean as well, but that causes problems with
# watch-make if you're generating intermediate files. If tests end up needing
# clean it's an indication of a missing dependency anyway.
.PHONY: test
test: testdeps install installcheck
	@if [ -r $(TESTOUT)/regression.diffs ]; then cat $(TESTOUT)/regression.diffs; fi

# make results: runs `make test` and copy all result files to expected
# DO NOT RUN THIS UNLESS YOU'RE CERTAIN ALL YOUR TESTS ARE PASSING!
#
# pg_regress workflow:
# 1. Converts input/*.source → sql/*.sql (with token substitution)
# 2. Converts output/*.source → expected/*.out (with token substitution)
# 3. Runs tests, saving actual output in results/
# 4. Compares results/ with expected/
#
# NOTE: Both input/*.source and output/*.source are COMPLETELY OPTIONAL and are
# very rarely needed. pg_regress does NOT create the input/ or output/ directories
# - these are optional INPUT directories that users create if they need them.
# Most extensions will never need these directories.
#
# CRITICAL: Do NOT copy files that have corresponding output/*.source files, because
# those are the source of truth and will be regenerated by pg_regress from the .source files.
# Only copy files from results/ that don't have output/*.source counterparts.
.PHONY: results
results: test
	@# Copy .out files from results/ to expected/, excluding those with output/*.source counterparts
	@# .out files with output/*.source counterparts are generated from .source files and should NOT be overwritten
	@$(PGXNTOOL_DIR)/make_results.sh $(TESTDIR) $(TESTOUT)

# testdeps is a generic dependency target that you can add targets to
.PHONY: testdeps
testdeps: pgtap

#
# pg_tle support - Generate pg_tle registration SQL
#

# PGXNTOOL_CONTROL_FILES is defined above (for control.mk dependencies)
PGXNTOOL_EXTENSIONS = $(basename $(PGXNTOOL_CONTROL_FILES))

# Main target
# Depend on 'all' to ensure versioned SQL files are generated first
# Depend on control.mk (which defines EXTENSION_VERSION_FILES)
# Depend on control files explicitly so changes trigger rebuilds
# Generates all supported pg_tle versions for each extension
.PHONY: pgtle
pgtle: all control.mk $(PGXNTOOL_CONTROL_FILES)
	@$(foreach ext,$(PGXNTOOL_EXTENSIONS),\
		$(PGXNTOOL_DIR)/pgtle.sh --extension $(ext);)

#
# pg_tle installation support
#

# Check if pg_tle is installed and report version
# Only reports version if CREATE EXTENSION pg_tle has been run
# Errors if pg_tle extension is not installed
# Uses pgtle.sh to get version (avoids code duplication)
.PHONY: check-pgtle
check-pgtle:
	@echo "Checking pg_tle installation..."
	@PGTLE_VERSION=$$($(PGXNTOOL_DIR)/pgtle.sh --get-version 2>/dev/null); \
	if [ -n "$$PGTLE_VERSION" ]; then \
		echo "pg_tle extension version: $$PGTLE_VERSION"; \
		exit 0; \
	fi; \
	echo "ERROR: pg_tle extension is not installed" >&2; \
	echo "       Run 'CREATE EXTENSION pg_tle;' first" >&2; \
	exit 1

# Run pg_tle registration SQL files
# Requires pg_tle extension to be installed (checked via check-pgtle)
# Uses pgtle.sh to determine which version range directory to use
# Assumes PG* environment variables are configured
.PHONY: run-pgtle
run-pgtle: pgtle
	@$(PGXNTOOL_DIR)/pgtle.sh --run

# These targets ensure all the relevant directories exist
$(TESTDIR)/sql $(TESTDIR)/expected/ $(TESTOUT)/results/:
	@mkdir -p $@
$(TEST_RESULT_FILES): | $(TESTDIR)/expected/
	@touch $@


#
# DOC SUPPORT
#
ASCIIDOC_HTML += $(filter %.html,$(foreach ext,$(ASCIIDOC_EXTS),$(ASCIIDOC_FILES:.$(ext)=.html)))
DOCS_HTML += $(ASCIIDOC_HTML)

# General ASCIIDOC template. This will be used to create rules for all ASCIIDOC_EXTS
define ASCIIDOC_template
%.html: %.$(1)
ifeq (,$(strip $(ASCIIDOC)))
	$$(warning Could not find "asciidoc" or "asciidoctor". Add one of them to your PATH,)
	$$(warning or set ASCIIDOC to the correct location.)
	$$(error Could not build %$$@)
endif # ifeq ASCIIDOC
	$$(ASCIIDOC) $$(ASCIIDOC_FLAGS) $$<
endef # define ASCIIDOC_template

# Create the actual rules
$(foreach ext,$(ASCIIDOC_EXTS),$(eval $(call ASCIIDOC_template,$(ext))))

# Create the html target regardless of whether we have asciidoc, and make it a dependency of dist
html: $(ASCIIDOC_HTML)
dist: html

# But don't add it as an install or test dependency unless we do have asciidoc
ifneq (,$(strip $(ASCIIDOC)))

# Need to do this so install & co will pick up ALL targets. Unfortunately this can result in some duplication.
DOCS += $(ASCIIDOC_HTML)

# Also need to add html as a dep to all (which will get picked up by install & installcheck
all: html

endif # ASCIIDOC

.PHONY: docclean
docclean:
	$(RM) $(DOCS_HTML)


#
# TAGGING SUPPORT
#
rmtag:
	git fetch origin # Update our remotes
	@test -z "$$(git tag --list $(PGXNVERSION))" || git tag -d $(PGXNVERSION)
	@test -z "$$(git ls-remote --tags origin $(PGXNVERSION) | grep -v '{}')" || git push --delete origin $(PGXNVERSION)

tag:
	@test -z "$$(git status --porcelain)" || (echo 'Untracked changes!'; echo; git status; exit 1)
	@# Skip if tag already exists and points to HEAD
	@if git rev-parse $(PGXNVERSION) >/dev/null 2>&1; then \
		if [ "$$(git rev-parse $(PGXNVERSION))" = "$$(git rev-parse HEAD)" ]; then \
			echo "Tag $(PGXNVERSION) already exists at HEAD, skipping"; \
		else \
			echo "ERROR: Tag $(PGXNVERSION) exists but points to different commit" >&2; \
			exit 1; \
		fi; \
	else \
		git tag $(PGXNVERSION); \
	fi
	git push origin $(PGXNVERSION)

.PHONY: forcetag
forcetag: rmtag tag

.PHONY: dist
dist: tag dist-only

dist-only:
	@# Check if .gitattributes exists but isn't committed
	@if [ -f .gitattributes ] && ! git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then \
		echo "ERROR: .gitattributes exists but is not committed to git." >&2; \
		echo "       git archive only respects export-ignore for committed files." >&2; \
		echo "       Please commit .gitattributes for export-ignore to take effect." >&2; \
		exit 1; \
	fi
	git archive --prefix=$(PGXN)-$(PGXNVERSION)/ -o ../$(PGXN)-$(PGXNVERSION).zip $(PGXNVERSION)

.PHONY: forcedist
forcedist: forcetag dist

# Target to list all targets
# http://stackoverflow.com/questions/4219255/how-do-you-get-the-list-of-targets-in-a-makefile
.PHONY: no_targets__ list
no_targets__:
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true


#
# subtree sync support
#
# This is setup to allow any number of pull targets by defining special
# variables. pgxntool-sync-release is an example of this.
#
# After the subtree pull, we run update-setup-files.sh to handle files that
# were initially copied by setup.sh (like .gitignore). This script does a
# 3-way merge if both you and pgxntool changed the file.
.PHONY: pgxntool-sync-%
pgxntool-sync-%:
	@old_commit=$$(git log -1 --format=%H -- pgxntool/); \
	git subtree pull -P pgxntool --squash -m "Pull pgxntool from $($@)" $($@); \
	pgxntool/update-setup-files.sh "$$old_commit"
pgxntool-sync: pgxntool-sync-release

# DANGER! Use these with caution. They may add extra crap to your history and
# could make resolving merges difficult!
pgxntool-sync-release	:= git@github.com:decibel/pgxntool.git release
pgxntool-sync-stable	:= git@github.com:decibel/pgxntool.git stable
pgxntool-sync-master	:= git@github.com:decibel/pgxntool.git master
pgxntool-sync-local		:= ../pgxntool release # Not the same as PGXNTOOL_DIR!
pgxntool-sync-local-stable	:= ../pgxntool stable # Not the same as PGXNTOOL_DIR!
pgxntool-sync-local-master	:= ../pgxntool master # Not the same as PGXNTOOL_DIR!

distclean:
	rm -f $(PGXNTOOL_distclean)

ifndef PGXNTOOL_NO_PGXS_INCLUDE

ifeq (,$(strip $(DOCS)))
DOCS =# Set to NUL so PGXS doesn't puke
endif

include $(PGXS)
#
# pgtap
#
# NOTE! This currently MUST be after PGXS! The problem is that
# $(DESTDIR)$(datadir) aren't being expanded. This can probably change after
# the META handling stuff is it's own makefile.
#
.PHONY: pgtap
installcheck: pgtap
pgtap: $(DESTDIR)$(datadir)/extension/pgtap.control

$(DESTDIR)$(datadir)/extension/pgtap.control:
	pgxn install pgtap --sudo

endif # fndef PGXNTOOL_NO_PGXS_INCLUDE
