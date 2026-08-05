# lint.mk — thin wrapper; the whole local footprint for consuming
# https://github.com/Postgres-Extensions/linter. Everything else lives in
# the .vendor/linter submodule; see its README for available targets/rules.
#
# Self-initializing (via the rule below) so `make lint` works right after a
# plain `git clone`, with no --recurse-submodules needed, and so CI can rely
# on the exact same entry point a developer would use locally.
#
# Guarded on a real .git being present (directory for a normal clone, or a
# `gitdir:` file for a worktree/submodule checkout -- $(wildcard .git) matches
# both). A source tarball (git archive output -- PGXN dist packages, `make
# dist`) has no .git at all and never contains submodule content, so without
# this guard GNU Make would still try to satisfy the `include` below via the
# remake rule on every invocation, `git submodule update --init` would fail
# immediately ("fatal: not a git repository"), and that failure would abort
# every `make` target -- not just `make lint` -- in a tarball build. Lint
# simply isn't available/attempted outside a real git checkout, which is
# correct: a tarball build has no reason to lint.
ifneq ($(wildcard .git),)

.vendor/linter/lint.mk:
	git submodule update --init -- .vendor/linter

include .vendor/linter/lint.mk

endif
